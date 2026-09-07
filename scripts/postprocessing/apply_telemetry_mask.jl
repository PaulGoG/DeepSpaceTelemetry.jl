"""
Point-wise mask expansion (command-line wrapper)
================================================

Expands one row of a run's batch-level `telemetry_mask_timeline.csv` into a
point-wise 0/1 availability array (`Receiver.expand_pointwise_mask`) without
reading the payload files: the output `pointwise_mask_tXXX.csv` states the
availability of every physical sample at the requested telemetry event.

Usage:
    julia apply_telemetry_mask.jl <run_id> <total_points> <event_row_index> <output_csv>
"""

using Pkg;
Pkg.activate(joinpath(@__DIR__, ".."), io = devnull);
Pkg.instantiate(io = devnull)
using DeepSpaceTelemetry

if length(ARGS) != 4
    println(
        "Usage: julia apply_telemetry_mask.jl <run_id> <total_points> <event_row_index> <output_csv>",
    )
    exit(1)
end

run_id = ARGS[1]
total_points = tryparse(Int, ARGS[2])
event_idx = tryparse(Int, ARGS[3])
output_csv = ARGS[4]
if total_points === nothing || event_idx === nothing
    println(
        "Error: <total_points> and <event_row_index> must be integers " *
        "(got \"$(ARGS[2])\", \"$(ARGS[3])\").",
    )
    exit(1)
end

DeepSpaceTelemetry.Receiver.expand_pointwise_mask(
    DeepSpaceTelemetry.TelemetryCore.run_directory(run_id),
    total_points,
    event_idx,
    output_csv,
)
