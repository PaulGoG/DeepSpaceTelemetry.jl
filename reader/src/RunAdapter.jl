"""
    RunAdapter

Run adapter for consumers: the geometry, batches, payload, arrivals, state,
and labeled intervals of the scenario of a run directory, read from the
file contract alone (the configuration snapshot, the batch directories,
`events_rx.csv`, `label_spans.csv`, the lifecycle sentinels), the same way
for an active run followed through its arrival feed and for a finished one
replayed from it. [`open_run`](@ref) checks the producer's version against
[`MINIMUM_PRODUCER_VERSION`](@ref); [`declared_holes`](@ref) reads the
holes of the delivered record from the producer's feed, `holes.csv`, and
[`delivered_rows`](@ref) the rows on the ground at any instant. The contract is the Analysis
Interfaces chapter of the manual; a consumer in another language reads the
same files.
"""
module RunAdapter

using ..TelemetryCore
using DataFrames: DataFrame, nrow
using Dates: DateTime

# The adapter follows the run-directory contract and is versioned with it:
# its names are public, for qualified use, and not exported.
public RunHandle,
    RunGeometry,
    BatchRecord,
    ArrivalEvent,
    Hole,
    FeedCursor,
    MINIMUM_PRODUCER_VERSION,
    open_run,
    run_geometry,
    run_state,
    record_final,
    list_batches,
    batch_rows,
    read_batch,
    read_batch_matrix,
    arrival_events,
    delivered_rows,
    markers,
    label_spans,
    declared_holes,
    row_time,
    time_row

"""
    MINIMUM_PRODUCER_VERSION

The oldest producer whose runs the adapter opens by default: 2.6.0, the
first to write the declared-hole feed `holes.csv` and `label_spans.csv`
beside the `payload_row` stamps of the batch metadata (2.1.0).
"""
const MINIMUM_PRODUCER_VERSION = v"2.6.0"

"""
    RunGeometry

The geometry of a run as a consumer needs it: `sample_rate` [Hz],
`segment_duration_sec`, `batch_size` (segments per batch),
`points_per_batch`, the mission epoch `start_sim_time`, the
`payload_origin` (the instant of payload row 1), `payload_rows` (the length
of an external record, `nothing` for a synthetic payload), the producer's
`package_version`, the clock `mode` (`"wall"` or `"tick"`), and the names
`columns` of the payload columns, from `provenance.external_data_columns` of
the configuration snapshot when present, else the one column
[`TelemetryCore.PAYLOAD_COLUMN_DEFAULT`](@ref).
"""
struct RunGeometry
    sample_rate::Float64
    segment_duration_sec::Float64
    batch_size::Int
    points_per_batch::Int
    start_sim_time::DateTime
    payload_origin::DateTime
    payload_rows::Union{Int,Nothing}
    package_version::String
    mode::String
    columns::Vector{String}
end

"""
    BatchRecord

One batch of the run: `name` (`LIVE_batch_<k>` or `ARCH_batch_<k>`), its
global `index` `k`, whether it is `live`, the payload `rows` it covers,
its `content_epoch` (the mission instant of its first sample, `missing`
for a batch written before the key existed), and its `state` — `:ground`
(payload readable), `:pruned` (delivered, payload removed by the retention
custodian), or `:lost` (retry budget exhausted, payload in `lost/`).
"""
struct BatchRecord
    name::String
    index::Int
    live::Bool
    rows::UnitRange{Int}
    content_epoch::Union{DateTime,Missing}
    state::Symbol
end

"""
    ArrivalEvent

One row of `events_rx.csv`: the mission instant `sim_time`, the `batch`,
the `event` (`:ingested`, `:retry`, `:lost`, `:pruned`), and the
`attempt` count the row carries.
"""
struct ArrivalEvent
    sim_time::DateTime
    batch::String
    event::Symbol
    attempt::Int
end

"""
    RunHandle

An opened run: its directory, its configuration snapshot, and its
[`RunGeometry`](@ref). Made by [`open_run`](@ref).
"""
struct RunHandle
    run_dir::String
    config::Dict{String,Any}
    geometry::RunGeometry
end

"""
    open_run(run::AbstractString; minimum_version = MINIMUM_PRODUCER_VERSION) -> RunHandle

Opens a run by directory path or by run identifier (resolved under the
data root). Throws an `ArgumentError` when the directory is not a run of
this package (no `config_snapshot.toml`, no lifecycle sentinel), or when
the producer's recorded version is older than `minimum_version`; a run
that records no version is opened with a warning.
"""
function open_run(
    run::AbstractString;
    minimum_version::VersionNumber = MINIMUM_PRODUCER_VERSION,
)
    run_dir = isdir(run) ? abspath(String(run)) : TelemetryCore.run_directory(String(run))
    isdir(run_dir) || throw(ArgumentError("[ADAPTER] No run directory $run_dir."))
    isfile(joinpath(run_dir, "config_snapshot.toml")) || throw(
        ArgumentError(
            "[ADAPTER] $run_dir holds no config_snapshot.toml: not a run directory of this package.",
        ),
    )
    any(
        isfile(joinpath(run_dir, s)) for s in ("RUN_ACTIVE", "RUN_COMPLETE", "RUN_ABORTED")
    ) || throw(ArgumentError("[ADAPTER] $run_dir carries no lifecycle sentinel."))
    cfg = TelemetryCore.load_run_config(run_dir)
    physics = TelemetryCore.physics_settings(cfg)
    sim = cfg["simulation"]
    provenance = get(cfg, "provenance", Dict{String,Any}())
    platform = get(provenance, "platform", Dict{String,Any}())
    version_text = String(get(platform, "package_version", ""))
    if isempty(version_text)
        @warn "[ADAPTER] $run_dir records no producer version: compatibility not checked."
    else
        version = tryparse(VersionNumber, version_text)
        version === nothing && throw(
            ArgumentError(
                "[ADAPTER] Unparsable producer version \"$version_text\" in $run_dir.",
            ),
        )
        version < minimum_version && throw(
            ArgumentError(
                "[ADAPTER] $run_dir was produced by DeepSpaceTelemetry $version; the adapter needs $minimum_version or later (the declared-hole feed holes.csv, label_spans.csv, payload_row stamps).",
            ),
        )
    end
    start_sim = DateTime(sim["start_sim_time"])
    origin = TelemetryCore.payload_origin(cfg)
    rows = get(provenance, "external_data_rows", nothing)
    geometry = RunGeometry(
        physics.sample_rate,
        physics.segment_duration_sec,
        physics.batch_size,
        TelemetryCore.points_per_batch(physics),
        start_sim,
        origin,
        rows isa Integer ? Int(rows) : nothing,
        version_text,
        TelemetryCore.simulation_mode(cfg),
        Vector{String}(
            get(
                provenance,
                "external_data_columns",
                [TelemetryCore.PAYLOAD_COLUMN_DEFAULT],
            ),
        ),
    )
    return RunHandle(run_dir, cfg, geometry)
end

"""
    run_geometry(run::RunHandle) -> RunGeometry

The run's [`RunGeometry`](@ref).
"""
run_geometry(run::RunHandle) = run.geometry

"""
    run_state(run::RunHandle) -> Symbol

The lifecycle state, from the sentinels: `:complete`, `:aborted`, or
`:active` (the pipeline may still write).
"""
function run_state(run::RunHandle)
    isfile(joinpath(run.run_dir, "RUN_COMPLETE")) && return :complete
    isfile(joinpath(run.run_dir, "RUN_ABORTED")) && return :aborted
    return :active
end

"""
    record_final(run::RunHandle) -> Bool

Whether the payload, the event logs, and the metrics profile are final:
the run has ended, or `RUN_POSTPROCESSING` stands beside `RUN_ACTIVE` and
only derived products are still being written.
"""
record_final(run::RunHandle) =
    run_state(run) !== :active || isfile(joinpath(run.run_dir, "RUN_POSTPROCESSING"))

"""
    row_time(geometry::RunGeometry, row::Integer) -> DateTime

The mission instant of payload row `row`: `payload_origin + (row − 1) /
sample_rate`, on the millisecond grid.
"""
row_time(g::RunGeometry, row::Integer) =
    TelemetryCore.payload_row_time(g.payload_origin, g.sample_rate, row)

"""
    time_row(geometry::RunGeometry, t::DateTime) -> Int

The payload row at the mission instant `t`, the inverse of
[`row_time`](@ref).
"""
time_row(g::RunGeometry, t::DateTime) =
    TelemetryCore.payload_time_row(g.payload_origin, g.sample_rate, t)

"""
    batch_rows(run::RunHandle, stage::AbstractString, name::AbstractString) -> UnitRange{Int}

The payload rows of the batch `name` under `<run_dir>/<stage>/`, from the
`payload_row` stamp of its metadata.
"""
function batch_rows(run::RunHandle, stage::AbstractString, name::AbstractString)
    g = run.geometry
    meta = TelemetryCore.read_batch_metadata(
        joinpath(run.run_dir, String(stage), String(name)),
    )
    return TelemetryCore.batch_hole_rows(
        get(meta, "payload_row", nothing),
        name,
        g.points_per_batch,
    )
end

"""
    list_batches(run::RunHandle) -> Vector{BatchRecord}

Every batch under `ground/` and `lost/`, sorted by
index, with its rows, content epoch, and state (a delivered batch whose
payload the custodian removed is `:pruned`).
"""
function list_batches(run::RunHandle)
    records = BatchRecord[]
    for (stage, state) in (("ground", :ground), ("lost", :lost))
        dir = joinpath(run.run_dir, stage)
        isdir(dir) || continue
        for name in readdir(dir)
            TelemetryCore.is_batch_name(name) && isdir(joinpath(dir, name)) || continue
            meta = TelemetryCore.read_batch_metadata(joinpath(dir, name))
            epoch =
                haskey(meta, "content_epoch") ?
                something(tryparse(DateTime, string(meta["content_epoch"])), missing) :
                missing
            final_state =
                state === :ground && isfile(joinpath(dir, name, "PRUNED")) ? :pruned : state
            push!(
                records,
                BatchRecord(
                    name,
                    TelemetryCore.batch_id(name),
                    TelemetryCore.is_live_batch(name),
                    batch_rows(run, stage, name),
                    epoch,
                    final_state,
                ),
            )
        end
    end
    sort!(records; by = r -> r.index)
    return records
end

"""
    segment_files(run::RunHandle, name::AbstractString) -> Tuple{String,Vector{String}}

The directory of the batch `name`, under `ground/` or, for a lost batch,
under `lost/`, and its segment file names in ascending segment identifier.
Throws an `ArgumentError` for a batch that is absent, pruned, or holds no
segment file.
"""
function segment_files(run::RunHandle, name::AbstractString)
    for stage in ("ground", "lost")
        dir = joinpath(run.run_dir, stage, String(name))
        isdir(dir) || continue
        isfile(joinpath(dir, "PRUNED")) && throw(
            ArgumentError(
                "[ADAPTER] The payload of $name was pruned by the retention custodian.",
            ),
        )
        files = filter(f -> occursin(r"^seg_\d+\.csv$", f), readdir(dir))
        isempty(files) &&
            throw(ArgumentError("[ADAPTER] $name holds no segment files in $dir."))
        sort!(files; by = f -> parse(Int, match(r"\d+", f).match))
        return dir, files
    end
    throw(
        ArgumentError("[ADAPTER] No batch $name under ground/ or lost/ of $(run.run_dir)."),
    )
end

"""
    read_batch_matrix(run::RunHandle, name::AbstractString) -> Matrix{Float32}

The samples of one batch, one row per sample and one column per payload
column of `run.geometry.columns`, its segments concatenated in ascending
segment identifier, from `ground/` or, for a lost batch, from `lost/`.
Throws an `ArgumentError` for a batch that is absent or pruned, and for a
segment whose columns differ from those of the geometry.
"""
function read_batch_matrix(run::RunHandle, name::AbstractString)
    dir, files = segment_files(run, name)
    expected = run.geometry.columns
    blocks = Matrix{Float32}[]
    for f in files
        seg = TelemetryCore.load_segment(joinpath(dir, f))
        seg.columns == expected || throw(
            ArgumentError(
                "[ADAPTER] $f of $name holds the columns $(join(seg.columns, ", ")); the run declares $(join(expected, ", ")).",
            ),
        )
        push!(blocks, seg.data)
    end
    return reduce(vcat, blocks)
end

"""
    read_batch(run::RunHandle, name::AbstractString;
               column::Union{Integer,AbstractString} = 1) -> Vector{Float32}

The samples of one payload column of one batch, by
index or by name, its segments concatenated in ascending segment
identifier, from `ground/` or, for a lost batch, from `lost/`
([`read_batch_matrix`](@ref) holds every column). For a one-column run the
default is the whole payload. Throws an `ArgumentError` for a batch that is
absent or pruned, and for a `column` that is not one of
`run.geometry.columns`.
"""
function read_batch(
    run::RunHandle,
    name::AbstractString;
    column::Union{Integer,AbstractString} = 1,
)
    columns = run.geometry.columns
    j = TelemetryCore.payload_column_index(columns, column)
    j === nothing && throw(
        ArgumentError(
            "[ADAPTER] No payload column $(repr(column)) in $(run.run_dir) (columns: $(join(columns, ", "))).",
        ),
    )
    return read_batch_matrix(run, name)[:, j]
end

"""
    arrival_events(run::RunHandle; after::Int = 0) -> Vector{ArrivalEvent}

The rows of `events_rx.csv` in file order, which is
mission-time order, beyond the first `after` rows. A streaming consumer
keeps the count of rows it has consumed and passes it here on every poll;
the feed is append-only, and a batch's payload is in `ground/` before its
`ingested` row is appended.
"""
function arrival_events(run::RunHandle; after::Int = 0)
    path = joinpath(run.run_dir, "events_rx.csv")
    isfile(path) || return ArrivalEvent[]
    table = TelemetryCore.read_table(path)
    after >= nrow(table) && return ArrivalEvent[]
    return [arrival_event(r) for r in eachrow(table[(after+1):end, :])]
end

# One row of events_rx.csv.
arrival_event(r) = ArrivalEvent(
    DateTime(r.SimTime),
    String(r.Batch),
    Symbol(lowercase(String(r.Event))),
    Int(r.Attempt),
)

"""
    delivered_rows(run::RunHandle; at::Union{DateTime,Nothing} = nothing)
        -> Vector{UnitRange{Int}}

The payload rows on the ground at mission instant `at`: the rows of every
batch with an `ingested` row in `events_rx.csv` at or before `at` (every
one when `at` is `nothing`), merged into sorted, disjoint intervals. The
rows come from the batches' `payload_row` stamps ([`batch_rows`](@ref)), so
they are exact across generation gaps and emitter restarts. A pruned batch
counts as delivered, as its delivery happened; [`list_batches`](@ref) tells
which payloads are still readable.

It replaces the point-wise masks of 2.x (`masks/pointwise_mask_*.csv`,
removed in 3.0), which placed batch `k` at row
`(k − 1) · points_per_batch + 1` and were wrong after the first generation
gap; on a run without one, the final mask was 1 exactly on these rows.
"""
function delivered_rows(run::RunHandle; at::Union{DateTime,Nothing} = nothing)
    rows = UnitRange{Int}[]
    for e in arrival_events(run)
        e.event === :ingested && (at === nothing || e.sim_time <= at) || continue
        push!(rows, batch_rows(run, "ground", e.batch))
    end
    return merge_intervals(rows)
end

# Sorted, disjoint union of row intervals; adjacent intervals are joined.
function merge_intervals(rows::Vector{UnitRange{Int}})
    merged = UnitRange{Int}[]
    for r in sort(rows; by = first)
        isempty(r) && continue
        if !isempty(merged) && first(r) <= last(merged[end]) + 1
            merged[end] = first(merged[end]):max(last(merged[end]), last(r))
        else
            push!(merged, r)
        end
    end
    return merged
end

"""
    markers(run::RunHandle) -> Vector{NamedTuple}

The event markers of the run, `(label, time, row)`, from `markers.csv`.
Empty when the run declares none.
"""
function markers(run::RunHandle)
    path = joinpath(run.run_dir, "markers.csv")
    isfile(path) || return NamedTuple{(:label, :time, :row),Tuple{String,DateTime,Int}}[]
    table = TelemetryCore.read_table(path)
    return [
        (label = String(r.Label), time = DateTime(r.SimTime), row = Int(r.PayloadRow)) for
        r in eachrow(table)
    ]
end

"""
    label_spans(run::RunHandle) -> Vector{NamedTuple}

The labeled intervals of the run's scenario from `label_spans.csv`
(2.6.0 and later), `(class, type, label, rows, content_start,
content_end)` with `rows` a `UnitRange{Int}` of payload rows: the
scenario's `[[labels]]` spans, the blackout and recovery phases of the
link disruptions, the scheduled generation gaps as configured, the
contact passes and low-latency periods, and the initial downtime. Empty
when the producer wrote no table.
"""
function label_spans(run::RunHandle)
    path = joinpath(run.run_dir, "label_spans.csv")
    isfile(path) || return NamedTuple{
        (:class, :type, :label, :rows, :content_start, :content_end),
        Tuple{String,String,String,UnitRange{Int},DateTime,DateTime},
    }[]
    text(x) = ismissing(x) ? "" : String(x)
    table = TelemetryCore.read_table(path)
    return [
        (
            class = String(r.Class),
            type = text(r.Type),
            label = text(r.Label),
            rows = Int(r.RowFirst):Int(r.RowLast),
            content_start = DateTime(r.ContentStart),
            content_end = DateTime(r.ContentEnd),
        ) for r in eachrow(table)
    ]
end

"""
    Hole

A declared hole of the delivered record: its `cause` (`:lost`, `:pruned`,
`:stream`, `:scheduled`, `:recorder`, and in the settled feed also
`:undelivered`, `:not_generated`), the `batch` for a batch-level hole
(`missing` for a generation gap or the unreached tail), its payload
`rows`, the content interval `[content_start, content_end)`, and
`declared_at`, the mission instant the producer declared the hole at.
`Hole(cause, batch, rows, content_start, content_end)` builds a hole
without a declaration instant (`missing`).
"""
struct Hole
    cause::Symbol
    batch::Union{String,Missing}
    rows::UnitRange{Int}
    content_start::DateTime
    content_end::DateTime
    declared_at::Union{DateTime,Missing}
end
Hole(
    cause::Symbol,
    batch::Union{String,Missing},
    rows::UnitRange{Int},
    content_start::DateTime,
    content_end::DateTime,
) = Hole(cause, batch, rows, content_start, content_end, missing)

"""
    declared_holes(run::RunHandle; after::Integer = 0) -> Vector{Hole}

The declared-hole feed `holes.csv` beyond its first `after` rows, each row
a [`Hole`](@ref) with its `declared_at`. The producer appends a hole the
moment it declares it and settles the feed with the end-of-run holes after
the mission phase, so that on a finished run it holds the holes of
`masks/gaps.csv`. Empty while no hole has been declared (the file appears
with the first).
"""
function declared_holes(run::RunHandle; after::Integer = 0)
    table = TelemetryCore.read_hole_feed(run.run_dir; after = after)
    return Hole[declared_hole(r) for r in eachrow(table)]
end

# One row of holes.csv.
declared_hole(r) = Hole(
    Symbol(String(r.Cause)),
    ismissing(r.Batch) ? missing : String(r.Batch),
    Int(r.RowFirst):Int(r.RowLast),
    DateTime(r.ContentStart),
    DateTime(r.ContentEnd),
    DateTime(r.DeclaredAt),
)

"""
    FeedCursor(run::RunHandle, feed::Symbol)

A position in one of the append-only feeds of a run, `:arrivals`
(`events_rx.csv`) or `:holes` (`holes.csv`): the byte offset past the last
complete line consumed and the count of rows read. Each call of
[`arrival_events`](@ref) or [`declared_holes`](@ref) on the cursor reads
only the bytes appended since the previous call, so following a feed costs
O(new rows) per poll, where the `after` forms re-read the whole file. A
line still being written (no terminating newline yet) is left for the next
call. No file handle is held between calls, and an absent file yields no
rows until it appears.

```julia
arrivals = RunAdapter.FeedCursor(run, :arrivals)
while RunAdapter.run_state(run) === :active
    for e in RunAdapter.arrival_events(arrivals)
        # consume e
    end
    sleep(poll_interval)
end
```
"""
mutable struct FeedCursor
    const path::String
    const feed::Symbol
    header::String
    offset::Int
    rows::Int
end

const FEED_FILES = (arrivals = "events_rx.csv", holes = "holes.csv")

function FeedCursor(run::RunHandle, feed::Symbol)
    haskey(FEED_FILES, feed) || throw(
        ArgumentError(
            "[ADAPTER] Unknown feed $(repr(feed)); expected :arrivals or :holes.",
        ),
    )
    return FeedCursor(joinpath(run.run_dir, FEED_FILES[feed]), feed, "", 0, 0)
end

"""
    arrival_events(cursor::FeedCursor) -> Vector{ArrivalEvent}

The rows of `events_rx.csv` appended since the previous call on an
`:arrivals` cursor ([`FeedCursor`](@ref)), advancing it.
"""
function arrival_events(cursor::FeedCursor)
    check_feed(cursor, :arrivals)
    return [arrival_event(r) for r in eachrow(next_rows!(cursor))]
end

"""
    declared_holes(cursor::FeedCursor) -> Vector{Hole}

The rows of `holes.csv` appended since the previous call on a `:holes`
cursor ([`FeedCursor`](@ref)), advancing it.
"""
function declared_holes(cursor::FeedCursor)
    check_feed(cursor, :holes)
    return Hole[declared_hole(r) for r in eachrow(next_rows!(cursor))]
end

check_feed(cursor::FeedCursor, feed::Symbol) =
    cursor.feed === feed || throw(
        ArgumentError(
            "[ADAPTER] A :$(cursor.feed) cursor cannot be read as the :$feed feed.",
        ),
    )

# The complete lines appended past the cursor, parsed under the feed's header;
# the cursor moves past them. The first complete line is the header.
function next_rows!(cursor::FeedCursor)
    isfile(cursor.path) || return DataFrame()
    bytes = open(cursor.path) do io
        seek(io, cursor.offset)
        read(io)
    end
    stop = findlast(==(UInt8('\n')), bytes)
    stop === nothing && return DataFrame()
    start = 1
    if isempty(cursor.header)
        eol = findfirst(==(UInt8('\n')), bytes)
        cursor.header = rstrip(String(bytes[1:(eol-1)]), '\r')
        start = eol + 1
    end
    cursor.offset += stop
    start > stop && return DataFrame()
    table = TelemetryCore.parse_table(cursor.header, view(bytes, start:stop))
    cursor.rows += nrow(table)
    return table
end

end # module RunAdapter
