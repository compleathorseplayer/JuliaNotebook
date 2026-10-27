#=
jnb: a minimal notebook for plain Julia files with `# %%` cell markers.

The file on disk stays an ordinary .jl file. The browser page shows one editor per cell.
Cells run in a separate Julia worker process (src/worker.jl): what a cell prints streams to
the page as it is printed, and its value is shown when it finishes (a plot as an image, a
table as HTML, anything else as text). Stop interrupts a cell; Restart starts a fresh worker.

Start it with the `jnb` launcher:   jnb coin_pfn.jl
=#
module Jnb

using HTTP, JSON3, Base64, Serialization, Sockets, Random

const ASSETS = normpath(joinpath(@__DIR__, "..", "assets"))
const WORKER_SCRIPT = joinpath(@__DIR__, "worker.jl")
const MARKER = r"^# %%"
const FRAME = codeunits("\x1eJNB:")
const SIGINT = 2

# ---------- file <-> cells ----------
# A new cell starts at every line beginning with `# %%`; the marker line belongs to the
# cell it opens. Anything before the first marker is a cell of its own. Joining the cells
# with "\n" reproduces the file byte for byte.
function split_cells(src::AbstractString)
    cells, cur = String[], SubString{String}[]
    for line in split(src, '\n')
        if occursin(MARKER, line) && !isempty(cur)
            push!(cells, join(cur, '\n'))
            empty!(cur)
        end
        push!(cur, line)
    end
    push!(cells, join(cur, '\n'))
    return cells
end

join_cells(cells) = join(cells, '\n')

# ---------- the worker process ----------
mutable struct Worker
    proc::Base.Process
    stdin::Pipe
    events::Channel{Any}    # (:out, text) | (:display, item) | (:done, result) | (:died, why)
end

# Number of bytes at the start of `buf[1:n]` that end on a whole UTF-8 character, so a
# character split across two reads is never sent as two halves.
function utf8_complete(buf, n)
    for back in 0:min(3, n - 1)
        b = buf[n - back]
        b & 0xC0 == 0x80 && continue                    # continuation byte: keep looking
        b < 0xC0 && return n                            # ASCII
        len = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2         # lead byte of a len-byte character
        return back + 1 >= len ? n : n - back - 1
    end
    return n
end

function find_frame(buf)
    n = length(FRAME)
    for i in 1:length(buf)
        buf[i] == FRAME[1] || continue
        k = min(n, length(buf) - i + 1)
        view(buf, i:i+k-1) == view(FRAME, 1:k) && return i   # a whole frame start, or the start of one
    end
    return nothing
end

# Read the worker's stdout, splitting it into printed text and framed messages.
function pump(w::Worker, out::Pipe)
    buf = UInt8[]
    while !eof(out)
        append!(buf, readavailable(out))
        while !isempty(buf)
            i = find_frame(buf)
            if i === nothing                             # all plain text
                k = utf8_complete(buf, length(buf))
                k > 0 && put!(w.events, (:out, String(buf[1:k])))
                deleteat!(buf, 1:k)
                break
            end
            i > 1 && put!(w.events, (:out, String(buf[1:i-1])))
            deleteat!(buf, 1:i-1)
            j = findfirst(==(UInt8('\n')), buf)
            (j === nothing || length(buf) < length(FRAME)) && break   # rest not here yet
            msg = deserialize(IOBuffer(base64decode(String(buf[length(FRAME)+1:j-1]))))
            deleteat!(buf, 1:j)
            put!(w.events, msg)
        end
    end
    isempty(buf) || put!(w.events, (:out, String(buf)))
    wait(w.proc)
    why = w.proc.termsignal != 0 ? "signal $(w.proc.termsignal)" : "exit code $(w.proc.exitcode)"
    put!(w.events, (:died, why))
end

function start_worker(dir)
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    # --project=@. : use the Project.toml in the notebook's folder or above, if there is
    # one; otherwise the default environment.
    cmd = `$julia --startup-file=no --threads=auto --project=@. --color=no
           -e "include($(repr(WORKER_SCRIPT))); JnbWorker.main()"`
    inp, out = Pipe(), Pipe()
    proc = run(pipeline(Cmd(cmd; dir), stdin = inp, stdout = out, stderr = out); wait = false)
    close(out.in)
    close(inp.out)
    w = Worker(proc, inp, Channel{Any}(Inf))
    errormonitor(@async pump(w, out))
    return w
end

# SIGKILL, not SIGTERM: on SIGTERM Julia prints every thread's backtrace, which would land
# in the running cell's output. The session is being thrown away, so nothing is lost.
const SIGKILL = 9
stop_worker(w::Worker) = process_running(w.proc) && kill(w.proc, SIGKILL)

# ---------- session state ----------
mutable struct Session
    path::String
    mtime::Float64          # file mtime when last loaded or saved, to catch edits made elsewhere
    token::String
    generation::Int         # bumped on every page load, so a reload cancels a pending shutdown
    worker::Worker
    runlock::ReentrantLock  # one cell at a time
    running::Bool
    interrupted::Bool       # at most one SIGINT per cell: a spare one would hit the next cell
end

function ensure_worker!(s::Session)
    process_running(s.worker.proc) || (s.worker = start_worker(dirname(s.path)))
    return s.worker
end

# Run one cell, calling `emit` with each event as it happens; returns when the cell is done
# or the worker died (Stop then Restart, or a crash). If `emit` fails because the page went
# away, keep reading until the cell finishes, so its output is not mistaken for the next one's.
function run_cell(emit, s::Session, code, line)
    lock(s.runlock) do
        w = ensure_worker!(s)
        while isready(w.events)                 # stray output printed between cells
            take!(w.events)
        end
        s.running, s.interrupted = true, false
        listening = true
        try
            serialize(w.stdin, (:run, code, line, s.path))
            flush(w.stdin)
            while true
                ev = take!(w.events)
                if listening
                    try
                        emit(ev)
                    catch
                        listening = false
                    end
                end
                ev[1] in (:done, :died) && break
            end
        finally
            s.running = false
        end
    end
end

event_json(ev) =
    ev[1] === :out     ? (kind = "out", text = ev[2]) :
    ev[1] === :display ? (kind = "display", item = ev[2]) :
    ev[1] === :done    ? (kind = "done", value = ev[2].value, error = ev[2].error, seconds = ev[2].seconds) :
    ev[2] == "signal $SIGKILL" ? (kind = "died", text = "Julia was restarted before this cell finished.") :
                         (kind = "died", text = "The Julia worker stopped ($(ev[2])). The next run starts a fresh one.")

# ---------- HTTP ----------
json(x; status = 200) = HTTP.Response(status, ["Content-Type" => "application/json"], JSON3.write(x))

const CONTENT_TYPES = Dict(".js" => "text/javascript", ".css" => "text/css",
                           ".html" => "text/html; charset=utf-8")

function asset(name)
    path = joinpath(ASSETS, basename(name))           # basename: no path traversal
    isfile(path) || return HTTP.Response(404, "not found")
    ctype = get(CONTENT_TYPES, splitext(path)[2], "application/octet-stream")
    return HTTP.Response(200, ["Content-Type" => ctype], read(path))
end

# Write the cells unless the file changed on disk since we last read or wrote it.
function save_cells(s::Session, cells; force = false)
    !force && isfile(s.path) && mtime(s.path) != s.mtime && return false
    write(s.path, join_cells(cells))
    s.mtime = mtime(s.path)
    return true
end

# The page was closed: stop, unless a page loads again soon (a reload sends bye, then load).
function schedule_exit(s::Session; grace = 3)
    g = s.generation
    @async begin
        sleep(grace)
        if s.generation == g
            println("jnb: browser window closed, stopping.")
            stop_worker(s.worker)
            exit(0)
        end
    end
end

function load_file(s::Session)
    s.generation += 1
    s.mtime = mtime(s.path)
    return (path = s.path, name = basename(s.path), cells = split_cells(read(s.path, String)))
end

function handler(s::Session, req::HTTP.Request)
    uri = HTTP.URI(req.target)
    p = uri.path
    startswith(p, "/assets/") && return asset(p[9:end])

    if p == "/"
        get(HTTP.queryparams(uri), "t", "") == s.token || return HTTP.Response(403, "bad token")
        html = replace(read(joinpath(ASSETS, "index.html"), String), "__TOKEN__" => s.token)
        return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], html)
    end

    # Every API call must carry the token: the server runs arbitrary code, and any web page
    # open in the browser could otherwise post to localhost.
    HTTP.header(req, "X-Jnb-Token") == s.token || return HTTP.Response(403, "bad token")
    body = isempty(req.body) ? nothing : JSON3.read(req.body)

    if p == "/api/load"
        return json(load_file(s))
    elseif p == "/api/save"
        save_cells(s, body.cells; force = get(body, :force, false)) ||
            return json((ok = false, reason = "changed"); status = 409)
        return json((ok = true,))
    elseif p == "/api/stop"
        if s.running && !s.interrupted && process_running(s.worker.proc)
            s.interrupted = true
            kill(s.worker.proc, SIGINT)
        end
        return json((ok = true,))
    elseif p == "/api/restart"
        stop_worker(s.worker)                  # a running cell ends with a "died" event
        lock(() -> (s.worker = start_worker(dirname(s.path))), s.runlock)
        return json((ok = true,))
    elseif p == "/api/bye"
        cells = body === nothing ? nothing : get(body, :cells, nothing)
        cells === nothing || save_cells(s, cells)   # never overwrites a file changed elsewhere
        schedule_exit(s)
        return json((ok = true,))
    end
    return HTTP.Response(404, "not found")
end

function authorized(s::Session, req::HTTP.Request)
    HTTP.header(req, "X-Jnb-Token") == s.token
end

# /api/run answers with newline-delimited JSON, one line per event, written as they happen.
function stream_run(s::Session, http::HTTP.Stream, body)
    HTTP.setstatus(http, 200)
    HTTP.setheader(http, "Content-Type" => "application/x-ndjson")
    HTTP.setheader(http, "Cache-Control" => "no-store")
    HTTP.startwrite(http)
    run_cell(s, String(body.code), Int(body.line)) do ev
        write(http, JSON3.write(event_json(ev)), "\n")
    end
end

function stream_handler(s::Session, http::HTTP.Stream)
    req = http.message
    req.body = read(http)
    HTTP.closeread(http)
    if HTTP.URI(req.target).path == "/api/run" && authorized(s, req)
        return stream_run(s, http, JSON3.read(req.body))
    end
    resp = handler(s, req)
    HTTP.setstatus(http, resp.status)
    for (k, v) in resp.headers
        HTTP.setheader(http, k => v)
    end
    HTTP.setheader(http, "Content-Length" => string(length(resp.body)))
    HTTP.startwrite(http)
    write(http, resp.body)
end

function open_in_browser(url)
    cmd = Sys.isapple()   ? `open $url` :
          Sys.iswindows() ? `cmd /c start "" $url` :
                            `xdg-open $url`
    try
        run(cmd; wait = false)
    catch
        println("jnb: could not open a browser; open the URL above yourself.")
    end
end

"""
    serve(path; port = 8765, open_browser = true)

Open `path` (a .jl file with `# %%` cells) as a notebook in the browser. Blocks until the
browser window is closed or Ctrl-C.
"""
function serve(path::AbstractString; port::Integer = 8765, open_browser::Bool = true)
    path = abspath(path)
    isfile(path) || touch(path)
    s = Session(path, mtime(path), randstring(24), 0, start_worker(dirname(path)),
                ReentrantLock(), false, false)

    port, sock = listenany(ip"127.0.0.1", port)
    url = "http://127.0.0.1:$port/?t=$(s.token)"
    println("jnb: $(basename(path))  ->  $url\n(close the browser window, or Ctrl-C, to stop)")
    flush(stdout)
    open_browser && open_in_browser(url)
    try
        HTTP.serve(http -> stream_handler(s, http), ip"127.0.0.1", port; server = sock, stream = true)
    finally
        stop_worker(s.worker)
    end
end

end # module
