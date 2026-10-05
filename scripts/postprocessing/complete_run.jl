include(joinpath(@__DIR__, "..", "activate.jl"))
using DeepSpaceTelemetry

# Completes a run whose supervisor died during post-processing: recomputes the
# products from the data on disk and settles RUN_ACTIVE into RUN_COMPLETE, or
# into RUN_ABORTED when the mission itself was cut short.
#
# Usage:
#     julia --threads=3 scripts/postprocessing/complete_run.jl <RUN_ID> [--force]
#
# --force skips the test for recent writes to the run directory.

const USAGE = "Usage: julia --threads=3 scripts/postprocessing/complete_run.jl <RUN_ID> [--force]"

positional = filter(a -> !startswith(a, "--"), ARGS)
if length(positional) != 1
    println(stderr, USAGE)
    exit(1)
end
run_id = only(positional)
run_dir = DeepSpaceTelemetry.Supervisor.complete_run(run_id; force = "--force" in ARGS)
println("Run settled: ", run_dir)
