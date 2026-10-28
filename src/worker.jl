#=
The jnb worker: runs notebook cells in its own Julia process, so the server stays free to
stream output, and a cell can be interrupted (SIGINT) or the whole session restarted.

Protocol, one cell at a time:
  server -> worker   stdin:  serialize((:run, code, firstline, path))
  worker -> server   stdout: whatever the cell prints, as it prints it, interleaved with
                             framed messages ending in a newline:  FRAME * base64(serialize(msg))
                             msg = (:display, item) | (:done, (value, error, seconds))
Both travel on stdout, so a cell's printed text always arrives before its result.

Only the standard library is used, so the worker runs in whatever environment the
notebook's folder selects (`--project=@.`) without needing jnb's own dependencies.
=#
module JnbWorker

using Base64, Serialization, Logging
import REPL

const FRAME = "\x1eJNB:"

function send(msg)
    io = IOBuffer()
    serialize(io, msg)
    write(stdout, FRAME, base64encode(take!(io)), "\n")
    flush(stdout)
end

# ---------- rendering a value ----------
const TEXT_CONTEXT = (:limit => true, :displaysize => (40, 120))

show_as(mime, x) = sprint(io -> show(IOContext(io, TEXT_CONTEXT...), MIME(mime), x))

function render(x)
    try
        showable("image/png", x) &&
            return (kind = "png", data = base64encode(repr(MIME("image/png"), x)))
        showable("text/html", x) && return (kind = "html", data = show_as("text/html", x))
        # typeset by the page (KaTeX); the plain text goes along in case it cannot be
        showable("text/latex", x) &&
            return (kind = "latex", data = show_as("text/latex", x), text = show_as("text/plain", x))
        return (kind = "text", data = show_as("text/plain", x))
    catch e
        return (kind = "error", data = "error while displaying value: " * sprint(showerror, e))
    end
end

# Sends explicit display(x) calls to the page as they happen, instead of opening windows.
struct CellDisplay <: AbstractDisplay end
Base.display(::CellDisplay, x) = (send((:display, Base.invokelatest(render, x))); nothing)
Base.display(d::CellDisplay, ::MIME, x) = display(d, x)

# Keep `d` on top of the display stack. Packages loaded mid-cell (Plots does this) push
# their own display, which would otherwise take display(x) calls away from the page.
function on_top!(d)
    ds = Base.Multimedia.displays
    filter!(x -> x !== d, ds)
    push!(ds, d)
end

# ---------- running a cell ----------
function format_error(e, bt)
    e isa LoadError && (e = e.error)
    e isa InterruptException && return "Interrupted."
    frames = stacktrace(bt)
    # Cut the trace at the cell itself; the frames below it are this worker's eval loop.
    i = findfirst(f -> f.func === Symbol("top-level scope"), frames)
    i === nothing || (frames = frames[1:i])
    return sprint() do io
        showerror(io, e)
        Base.show_backtrace(io, frames)
    end
end

# Evaluate each top-level expression of `code` in Main, as the REPL would. `firstline` is
# the cell's line number in the file, so errors and @__LINE__ point at the real line.
function run_exprs!(code, firstline, path, d)
    ast = Meta.parseall("\n"^(firstline - 1) * code; filename = path)
    result = nothing
    line = LineNumberNode(firstline, Symbol(path))
    for ex in ast.args
        if ex isa LineNumberNode
            line = ex
            continue
        end
        on_top!(d)
        result = Core.eval(Main, Expr(:toplevel, line, ex))
    end
    return result
end

function run_cell(code, firstline, path)
    d = CellDisplay()
    t0 = time()
    value, err = nothing, nothing
    try
        # Ctrl-C (SIGINT from the server's Stop button) may only land inside the user's code;
        # anywhere else it could cut a protocol message in half.
        result = reenable_sigint() do
            task_local_storage(:SOURCE_PATH, path) do
                run_exprs!(code, firstline, path, d)
            end
        end
        if result !== nothing && !REPL.ends_with_semicolon(code)
            # invokelatest: the cell may have defined methods this call would not see.
            value = Base.invokelatest(render, result)
        end
    catch e
        err = format_error(e, catch_backtrace())
    finally
        filter!(x -> x !== d, Base.Multimedia.displays)
    end
    send((:done, (value = value, error = err, seconds = round(time() - t0; digits = 2))))
end

function main()
    Base.exit_on_sigint(false)                 # SIGINT interrupts the cell, not the process
    global_logger(ConsoleLogger(stderr))       # stderr is the same pipe as stdout
    disable_sigint() do
        while true
            cmd = try
                deserialize(stdin)
            catch e
                e isa EOFError && return       # the server has gone: stop with it
                rethrow()
            end
            cmd[1] === :run && run_cell(cmd[2], cmd[3], cmd[4])
        end
    end
end

end # module
