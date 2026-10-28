# Expands one row of a run's batch-level telemetry_mask_timeline.csv into a
# point-wise 0/1 availability array (Masks.expand_pointwise_mask) without
# reading the payload files: the availability of every physical sample at
# the requested telemetry event.
#
# Deprecated since 2.11.0 and removed in 3.0 (RunAdapter.delivered_rows).

include(joinpath(@__DIR__, "..", "activate.jl"))
using DeepSpaceTelemetry

println(
    stderr,
    "Deprecated since 2.11.0 and removed in 3.0: the point-wise mask places " *
    "batches by position and is wrong after a generation gap. " *
    "RunAdapter.delivered_rows gives the delivered payload rows at any instant.",
)

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
    @error(
        "<total_points> and <event_row_index> must be integers",
        total_points = ARGS[2],
        event_row_index = ARGS[3],
    )
    exit(1)
end

DeepSpaceTelemetry.Masks.expand_pointwise_mask(
    DeepSpaceTelemetry.TelemetryCore.run_directory(run_id),
    total_points,
    event_idx,
    output_csv,
)
