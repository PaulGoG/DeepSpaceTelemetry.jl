# Activates and instantiates the script environment silently. The entry
# points include it first (follow_log.jl excepted); `julia -i scripts/activate.jl`,
# or `include` from a REPL, opens an interactive session in it. The first
# instantiation resolves and precompiles and is slow; later ones are no-ops.

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
