@echo off
rem jnb FILE.jl [PORT] -- open a Julia file with # %%%% cells as a notebook in the browser.
julia --startup-file=no --project="%~dp0.." "%~dp0..\src\main.jl" %*
