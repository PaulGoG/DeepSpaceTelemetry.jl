# Activates and instantiates the test environment of the headless package
# silently; `julia headless/test/runtests.jl` includes it first.

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
