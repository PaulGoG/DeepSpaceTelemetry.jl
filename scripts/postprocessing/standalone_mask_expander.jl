"""
Standalone mask expander
========================

Dependency-light copy of the point-wise mask expansion for collaborators who
consume run products without the package: only the registered packages `CSV`
and `DataFrames` are needed. Expands one row of a run's compact
`telemetry_mask_timeline.csv` into a point-wise 0/1 availability column that
multiplies raw time series in Python, MATLAB, or C++.

Usage:
    julia standalone_mask_expander.jl <path_to_matrix.csv> <points_per_batch> <target_row_idx> <output.csv>

Example:
    julia standalone_mask_expander.jl telemetry_mask_timeline.csv 921600 100 pointwise_mask.csv

The test suite checks this script against `Masks.expand_pointwise_mask`. Like
the library's point-wise product, it places batches positionally and ignores
generation gaps (see the manual's analysis-interfaces page).
"""

# Not installed automatically: that would modify the caller's active environment.
try
    using CSV, DataFrames
catch e
    e isa ArgumentError || rethrow()
    println(
        "Missing required packages (CSV, DataFrames). Install them into " *
        "your active environment first:",
    )
    println("    julia -e 'using Pkg; Pkg.add([\"CSV\", \"DataFrames\"])'")
    exit(1)
end

"""
    expand_pointwise_mask(matrix_path::String, points_per_batch::Int, event_idx::Int, output_path::String)

Expands row `event_idx` (`-1`: the last row) of the mask timeline at
`matrix_path` into `points_per_batch` samples per batch and writes them to
`output_path` as an `Int8` 0/1 column. Only batches on the ground (state 3)
give 1; not yet generated (0), onboard (1), on the link (2), and
permanently lost (4) give 0. An existing `output_path` is rotated to
`<stem>#k<ext>`, not overwritten.
"""
function expand_pointwise_mask(
    matrix_path::String,
    points_per_batch::Int,
    event_idx::Int,
    output_path::String,
)
    if !isfile(matrix_path)
        error("Telemetry matrix not found at: $matrix_path")
    end

    println("Loading mask timeline from: $matrix_path")
    # ntasks = 1: one wide row per event defeats CSV.jl's multithreaded
    # chunking, which logs a failure before falling back to a single task.
    mask_df = CSV.read(matrix_path, DataFrame; ntasks = 1, types = Dict(:SimTime => String))

    target_idx = event_idx == -1 ? nrow(mask_df) : event_idx

    if target_idx < 1 || target_idx > nrow(mask_df)
        error(
            "Event index $target_idx is out of bounds. The timeline has $(nrow(mask_df)) events.",
        )
    end

    event_row = mask_df[target_idx, :]
    event_time = event_row.SimTime
    println("Selected Telemetry Event: $event_time (Row $target_idx)")

    # Isolate just the batch columns (drop 'SimTime')
    batch_statuses = Vector(event_row[2:end])

    total_points = length(batch_statuses) * points_per_batch
    println(
        "Expanding $(length(batch_statuses)) batches into a point-wise 0/1 array for $total_points points...",
    )

    # 0 = Unavailable, 1 = Available on Ground
    point_mask = zeros(Int8, total_points)

    for (batch_index, status) in enumerate(batch_statuses)
        if status == 3
            start_idx = (batch_index - 1) * points_per_batch + 1
            end_idx = start_idx + points_per_batch - 1
            point_mask[start_idx:end_idx] .= 1
        end
    end

    println("Saving pointwise mask to: $output_path")
    # Rotate any pre-existing output to name#k.csv instead of overwriting
    # (mirrors TelemetryCore.safe_csv_write without requiring the package).
    if isfile(output_path)
        stem, ext = splitext(output_path)
        k = 1
        while isfile("$stem#$k$ext")
            k += 1
        end
        mv(output_path, "$stem#$k$ext")
        println("Existing output rotated to: $stem#$k$ext")
    end
    output_df = DataFrame(Time_Index = 1:total_points, Ground_Available = point_mask)
    CSV.write(output_path, output_df)

    available_pts = count(x -> x == 1, point_mask)
    avail_pct = round((available_pts / total_points) * 100, digits = 2)

    println("\n=== MASK EXPANSION COMPLETE ===")
    println("Total Data Points:     $total_points")
    println("Available on Ground:   $available_pts ($avail_pct%)")
    println("Unavailable:           $(total_points - available_pts)")
end

if abspath(PROGRAM_FILE) == @__FILE__
    if length(ARGS) != 4
        println(
            "Usage: julia standalone_mask_expander.jl <matrix.csv> <points_per_batch> <target_row_idx> <output.csv>",
        )
        exit(1)
    end

    mat_csv = ARGS[1]
    ppb = tryparse(Int, ARGS[2])
    idx = tryparse(Int, ARGS[3])
    out_csv = ARGS[4]
    if ppb === nothing || idx === nothing
        @error(
            "<points_per_batch> and <target_row_idx> must be integers",
            points_per_batch = ARGS[2],
            target_row_idx = ARGS[3],
        )
        exit(1)
    end
    if !isfile(mat_csv)
        @error "Matrix CSV not found" path = mat_csv
        exit(1)
    end

    expand_pointwise_mask(mat_csv, ppb, idx, out_csv)
end
