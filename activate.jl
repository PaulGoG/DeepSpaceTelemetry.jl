# Activates and instantiates the package environment silently. Every entry
# point of the environment includes it first; `julia -i activate.jl`,
# or `include` from a REPL, opens an interactive session in it. The first
# instantiation resolves and precompiles and is slow; later ones are no-ops.

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
