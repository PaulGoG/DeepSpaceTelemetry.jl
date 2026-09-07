"""
Standalone Mask Expander
========================

This is an independent script designed to be shared with external collaborators.
It does NOT require the full `DeepSpaceTelemetry` package or any custom modules.
It only requires standard open-source Julia packages (`CSV`, `DataFrames`).

It converts a compact 2D `telemetry_mask_timeline.csv` (provided by the
simulator) into a high-resolution 1D column of 0s and 1s that can be multiplied
against raw time-series data in Python, MATLAB, or C++.

Usage:
    julia standalone_mask_expander.jl <path_to_matrix.csv> <points_per_batch> <target_row_idx> <output.csv>

Example:
    julia standalone_mask_expander.jl telemetry_mask_timeline.csv 921600 100 pointwise_mask.csv
"""

# Required registered packages; never installed implicitly — installing into
# the caller's active environment without consent is not this script's call.
try
    using CSV, DataFrames
catch
    println(
        "Missing required packages (CSV, DataFrames). Install them into " *
        "your active environment first:",
    )
    println("    julia -e 'using Pkg; Pkg.add([\"CSV\", \"DataFrames\"])'")
    exit(1)
end

"""
    expand_pointwise_mask(matrix_path::String, points_per_batch::Int, event_idx::Int, output_path::String)

Reads a given `telemetry_mask_timeline.csv` matrix and extracts a single row 
(specified by `event_idx`). It then expands each batch status (0-4) into a 
high-resolution pointwise boolean array of size `points_per_batch` per batch. 
Only successfully downlinked batches (status == 3) result in 1s; batches that
were still onboard/in transit (1, 2), not yet generated (0), or permanently
lost to packet loss (4) stay 0.
Saves the resulting integer array to `output_path`.
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
    mask_df = CSV.read(matrix_path, DataFrame)

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
        # Status 3 means 'Ground Archive' (Successfully downlinked).
        # 0/1/2 (not yet down) and 4 (Lost) stay masked.
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
        println(
            "Error: <points_per_batch> and <target_row_idx> must be integers " *
            "(got \"$(ARGS[2])\", \"$(ARGS[3])\").",
        )
        exit(1)
    end
    if !isfile(mat_csv)
        println("Error: matrix CSV not found at $mat_csv")
        exit(1)
    end

    expand_pointwise_mask(mat_csv, ppb, idx, out_csv)
end
