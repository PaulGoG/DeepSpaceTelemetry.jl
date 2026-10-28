# --- Batch & Segment I/O ---
"""
    save_batch(path::String, batch::DataBatch; markers = String[], payload_row = nothing)

Writes `batch` into the directory `path`: `metadata.json` and one
`seg_<id>.csv` per segment ([`save_segment`](@ref)), one column per payload
column. The metadata carries `batch_id`, `segment_count`, `created_at` (the
mission instant the batch was finalized and became transmittable),
`content_epoch` (the mission timestamp of its first sample, the physical
epoch of the data), and, when given, `payload_row` (the 1-based row of that
sample in the payload series starting at the payload origin) and `markers`
(the labels of the event markers whose instant lies in the payload).
"""
function save_batch(
    path::String,
    batch::DataBatch;
    markers::Vector{String} = String[],
    payload_row::Union{Int,Nothing} = nothing,
)
    mkpath(path)
    content_epoch = isempty(batch.segments) ? batch.created_at : batch.segments[1].timestamp
    metadata = Dict{String,Any}(
        "batch_id" => batch.id,
        "segment_count" => length(batch.segments),
        "created_at" => string(batch.created_at),
        "content_epoch" => string(content_epoch),
    )
    payload_row === nothing || (metadata["payload_row"] = payload_row)
    isempty(markers) || (metadata["markers"] = markers)
    open(joinpath(path, "metadata.json"), "w") do io
        JSON.json(io, metadata)
    end

    for seg in batch.segments
        save_segment(joinpath(path, "seg_$(seg.id).csv"), seg)
    end
end

"""
    read_batch_metadata(batch_dir::String) -> Dict{String,Any}

Parses `<batch_dir>/metadata.json`. Returns an empty dictionary when the file
is absent, since a directory without it is not a batch. An unparsable file
(a truncated or corrupted batch) is an `ArgumentError` naming the directory.
"""
function read_batch_metadata(batch_dir::String)
    path = joinpath(batch_dir, "metadata.json")
    isfile(path) || return Dict{String,Any}()
    text = read(path, String)
    parsed = try
        JSON.parse(text; dicttype = Dict{String,Any})
    catch e
        e isa InterruptException && rethrow()
        throw(
            ArgumentError(
                "[BATCH] Unparsable metadata.json in $batch_dir: $(sprint(showerror, e))",
            ),
        )
    end
    return parsed
end

"""
    batch_metadata_values(parse_value, run_dir::String, key::String, T::Type) -> Dict{String,T}

Batch name → `parse_value(meta[key])` for every batch directory under
`onboard/`, `link/`, `ground/`, and `lost/` whose `metadata.json` records
`key`; batches without the key, or whose value `parse_value` maps to
`nothing`, are omitted.
"""
function batch_metadata_values(parse_value, run_dir::String, key::String, T::Type)
    found = Dict{String,T}()
    for sub in ("onboard", "link", "ground", "lost")
        dir = joinpath(run_dir, sub)
        isdir(dir) || continue
        for name in readdir(dir)
            batch_dir = joinpath(dir, name)
            isdir(batch_dir) || continue
            meta = read_batch_metadata(batch_dir)
            haskey(meta, key) || continue
            value = parse_value(meta[key])
            value === nothing || (found[name] = value)
        end
    end
    return found
end

"""
    batch_content_epochs(run_dir::String) -> Dict{String,DateTime}

Batch name → content epoch (first-sample mission timestamp) for every batch
directory under `onboard/`, `link/`, `ground/`, and `lost/` whose
`metadata.json` records a `content_epoch` (batches written before that key
existed are omitted).
"""
function batch_content_epochs(run_dir::String)
    return batch_metadata_values(
        v -> tryparse(DateTime, string(v)),
        run_dir,
        "content_epoch",
        DateTime,
    )
end

"""
    batch_payload_rows(run_dir::String) -> Dict{String,Int}

Batch name → payload row of the first sample for every batch directory
under `onboard/`, `link/`, `ground/`, and `lost/` whose `metadata.json`
records a `payload_row`.
"""
function batch_payload_rows(run_dir::String)
    return batch_metadata_values(
        v -> v isa Integer ? Int(v) : nothing,
        run_dir,
        "payload_row",
        Int,
    )
end

"""
    save_segment(path::String, seg::DataSegment)

Writes the samples of `seg` to the CSV at `path`, one column per payload
column under its name. A segment named [`PAYLOAD_COLUMN_DEFAULT`](@ref)
writes the single `Amplitude` column of releases before 2.6.0.
"""
function save_segment(path::String, seg::DataSegment)
    df = DataFrame([seg.data[:, j] for j in 1:length(seg.columns)], seg.columns)
    write_table(path, df)
end

"""
    load_segment(path::String; timestamp::DateTime = DateTime(0)) -> DataSegment

Reads a segment CSV written by [`save_segment`](@ref) back into a
[`DataSegment`](@ref), one payload column per file column under its header
name; the identifier comes from the file name `seg_<id>.csv` (0 when it does
not conform). A non-numeric column raises an `ArgumentError` naming the file
and the column. The file holds samples only, so a caller that knows the
mission timestamp passes it as `timestamp` (the batch's `content_epoch` in
`metadata.json` is that of its first segment); the default `DateTime(0)`
marks it unknown.
"""
function load_segment(path::String; timestamp::DateTime = DateTime(0))
    df = read_table(path)
    id_match = match(r"seg_(\d+)\.csv", basename(path))
    # The capture is a Union{Nothing, SubString}: guard the full chain so a
    # nonconforming filename degrades to id 0 instead of throwing.
    id = id_match !== nothing ? something(tryparse(Int, something(id_match[1], "")), 0) : 0
    columns = String.(names(df))
    data = Matrix{Float32}(undef, DataFrames.nrow(df), length(columns))
    for j in eachindex(columns)
        column = df[!, j]
        eltype(column) <: Real || throw(
            ArgumentError(
                "Segment file $path: column $(columns[j]) is not numeric (eltype $(eltype(column))).",
            ),
        )
        data[:, j] = Vector{Float32}(column)
    end
    return DataSegment(id, timestamp, data, columns)
end
