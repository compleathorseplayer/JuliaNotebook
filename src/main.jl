#=
Entry point for the jnb launcher, run as:  julia --project=<app folder> src/main.jl FILE.jl [PORT]

The server uses only the app's own environment (Project.toml/Manifest.toml in the app folder)
and the standard library. Narrowing LOAD_PATH means it can't quietly depend on whatever is in
the user's default environment. This affects the server process only: notebook cells run in
the worker process, which chooses its environment separately (see start_worker in Jnb.jl).
=#
empty!(LOAD_PATH)
append!(LOAD_PATH, ["@", "@stdlib"])

if isempty(ARGS)
    println("usage: jnb FILE.jl [PORT]")
    exit(1)
end

try
    import HTTP, JSON3
catch
    # First run: fetch the app's two dependencies into Julia's package store. This doesn't
    # touch any of the user's environments, only the app's own (already listed in Manifest.toml).
    println("jnb: first run, installing its dependencies (HTTP, JSON3)…")
    import Pkg
    Pkg.instantiate()
end

include(joinpath(@__DIR__, "Jnb.jl"))
Jnb.serve(ARGS[1]; port = length(ARGS) > 1 ? parse(Int, ARGS[2]) : 8765,
          open_browser = !haskey(ENV, "JNB_NO_BROWSER"))
