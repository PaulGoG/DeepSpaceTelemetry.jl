# Activates and instantiates the test environment silently. Every entry
# point of the environment includes it first; `julia -i test/activate.jl`,
# or `include` from a REPL, opens an interactive session in it. The first
# instantiation resolves and precompiles and is slow; later ones are no-ops.

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
