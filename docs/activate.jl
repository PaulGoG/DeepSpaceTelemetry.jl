"""
Activate and instantiate the documentation environment, silently.

    julia -i docs/activate.jl

Run this way it leaves a REPL with the environment active and its manifest
instantiated; from an existing REPL, `include` it for the same effect. The
first instantiation of an environment resolves and precompiles and is
therefore slow; afterwards it is a no-op.

Every entry point of the package performs these same two calls on start-up,
so running a script directly needs no preparation. This file exists for
interactive work.
"""

using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
