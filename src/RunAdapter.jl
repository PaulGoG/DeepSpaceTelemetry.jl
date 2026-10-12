"""
    RunAdapter

The reference run adapter: the five questions a consumer asks of a run
directory — geometry, batches, payload, arrivals, state — answered from the
file contract alone (the configuration snapshot, the batch directories,
`events_rx.csv`, the lifecycle sentinels), the same way for an active run
followed through its arrival feed and for a finished one replayed from it.
[`open_run`](@ref) checks the producer's version against
[`MINIMUM_PRODUCER_VERSION`](@ref); [`GapTracker`](@ref) declares the holes
of the delivered record as the feeds announce them, with the rules of
[`Masks.gap_table`](@ref). A consumer in another language reads the same
files; the manual's Analysis Interfaces chapter is the contract.
"""
module RunAdapter

using ..TelemetryCore
using DataFrames: nrow
using Dates: DateTime, Millisecond, Dates

"""
    MINIMUM_PRODUCER_VERSION

The oldest producer whose runs the adapter opens by default: 2.1.0, the
first to stamp `payload_row` into the batch metadata, so a batch's rows are
exact across generation gaps and emitter restarts.
"""
const MINIMUM_PRODUCER_VERSION = v"2.1.0"

"""
    GAP_LABELS

The `Batch` values of the generation-gap rows of `events_tx.csv`.
"""
const GAP_LABELS = ("STREAM", "SCHEDULED", "RECORDER")

"""
    RunGeometry

The geometry of a run as a consumer needs it: `sample_rate` [Hz],
`segment_duration_sec`, `batch_size` (segments per batch),
`points_per_batch`, the mission epoch `start_sim_time`, the
`payload_origin` (the instant of payload row 1), `payload_rows` (the length
of an external record, `nothing` for a synthetic payload), the producer's
`package_version`, and the clock `mode` (`"wall"` or `"tick"`).
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
                "[ADAPTER] $run_dir was produced by DeepSpaceTelemetry $version; the adapter needs $minimum_version or later (batch metadata with payload_row).",
            ),
        )
    end
    start_sim = DateTime(sim["start_sim_time"])
    origin =
        haskey(provenance, "payload_origin") ? DateTime(provenance["payload_origin"]) :
        start_sim - Millisecond(
            round(
                Int,
                Float64(get(sim, "initial_downtime_days", 0.0)) * TelemetryCore.MS_PER_DAY,
            ),
        )
    rows = get(provenance, "external_data_rows", nothing)
    geometry = RunGeometry(
        physics.sample_rate,
        physics.segment_duration_sec,
        physics.batch_size,
        round(Int, physics.sample_rate * physics.segment_duration_sec) * physics.batch_size,
        start_sim,
        origin,
        rows isa Integer ? Int(rows) : nothing,
        version_text,
        TelemetryCore.simulation_mode(cfg),
    )
    return RunHandle(run_dir, cfg, geometry)
end

"""
    run_geometry(run::RunHandle) -> RunGeometry

The first question: the run's [`RunGeometry`](@ref).
"""
run_geometry(run::RunHandle) = run.geometry

"""
    run_state(run::RunHandle) -> Symbol

The fifth question, from the sentinels: `:complete`, `:aborted`, or
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
    g.payload_origin + Millisecond(round(Int, 1000 * (row - 1) / g.sample_rate))

"""
    time_row(geometry::RunGeometry, t::DateTime) -> Int

The payload row at the mission instant `t`, the inverse of
[`row_time`](@ref).
"""
time_row(g::RunGeometry, t::DateTime) =
    round(Int, Dates.value(t - g.payload_origin) * g.sample_rate / 1000) + 1

"""
    batch_rows(run::RunHandle, stage::AbstractString, name::AbstractString) -> UnitRange{Int}

The payload rows of the batch `name` under `<run_dir>/<stage>/`, from the
`payload_row` stamp of its metadata, or from its index when the stamp is
absent (a run before 2.1.0, which has no gap rows either).
"""
function batch_rows(run::RunHandle, stage::AbstractString, name::AbstractString)
    g = run.geometry
    meta = TelemetryCore.read_batch_metadata(
        joinpath(run.run_dir, String(stage), String(name)),
    )
    first = get(meta, "payload_row", nothing)
    first isa Integer ||
        (first = (TelemetryCore.batch_id(name) - 1) * g.points_per_batch + 1)
    return Int(first):(Int(first)+g.points_per_batch-1)
end

"""
    list_batches(run::RunHandle) -> Vector{BatchRecord}

The second question: every batch under `ground/` and `lost/`, sorted by
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
    read_batch(run::RunHandle, name::AbstractString) -> Vector{Float32}

The third question: the samples of one batch, its segments concatenated in
ascending segment identifier, from `ground/` or, for a lost batch, from
`lost/`. Throws an `ArgumentError` for a batch that is absent or pruned.
"""
function read_batch(run::RunHandle, name::AbstractString)
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
        return reduce(
            vcat,
            (TelemetryCore.load_segment(joinpath(dir, f)).data for f in files),
        )
    end
    throw(
        ArgumentError("[ADAPTER] No batch $name under ground/ or lost/ of $(run.run_dir)."),
    )
end

"""
    arrival_events(run::RunHandle; after::Int = 0) -> Vector{ArrivalEvent}

The fourth question: the rows of `events_rx.csv` in file order, which is
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
    return [
        ArrivalEvent(
            DateTime(r.SimTime),
            String(r.Batch),
            Symbol(lowercase(String(r.Event))),
            Int(r.Attempt),
        ) for r in eachrow(table[(after+1):end, :])
    ]
end

"""
    markers(run::RunHandle) -> Vector{NamedTuple}

The event markers of the run, `(label, time, row)`: the `PayloadRow` of
`markers.csv` where the producer wrote it (2.5.0 and later), computed
from the instant otherwise. Empty when the run declares none.
"""
function markers(run::RunHandle)
    path = joinpath(run.run_dir, "markers.csv")
    isfile(path) || return NamedTuple{(:label, :time, :row),Tuple{String,DateTime,Int}}[]
    table = TelemetryCore.read_table(path)
    stamped = "PayloadRow" in names(table)
    return [
        (
            label = String(r.Label),
            time = DateTime(r.SimTime),
            row = stamped ? Int(r.PayloadRow) : time_row(run.geometry, DateTime(r.SimTime)),
        ) for r in eachrow(table)
    ]
end

"""
    Hole

A declared hole of the delivered record: its `cause` (`:lost`, `:pruned`,
`:stream`, `:scheduled`, `:recorder`), the `batch` for a batch-level
hole (`missing` for a generation gap), its payload `rows`, and the content
interval `[content_start, content_end)`.
"""
struct Hole
    cause::Symbol
    batch::Union{String,Missing}
    rows::UnitRange{Int}
    content_start::DateTime
    content_end::DateTime
end

"""
    GapTracker(run::RunHandle)

The streaming form of the gap table: a cursor over `events_rx.csv` and
`events_tx.csv` that turns each new `lost` or `pruned` row into a
[`Hole`](@ref) at once and each closed `gap_start` / `gap_end` pair into
one, so a streaming consumer declares a permanent hole the moment the
producer does rather than discovering it from the spacing of the content
epochs. [`declare!`](@ref) returns the holes new since the last call;
[`open_gaps`](@ref) lists the generation gaps that have opened and not
closed. On a finished run one call declares the same lost, pruned, and
generation-gap holes as [`Masks.gap_table`](@ref); the undelivered and
unreached rows of that table are end-of-run categories a feed cannot
announce.
"""
mutable struct GapTracker
    const run::RunHandle
    rx_cursor::Int
    tx_cursor::Int
    const open::Dict{String,DateTime}
    const declared::Vector{Hole}
end

GapTracker(run::RunHandle) = GapTracker(run, 0, 0, Dict{String,DateTime}(), Hole[])

"""
    declare!(tracker::GapTracker) -> Vector{Hole}

Reads the rows of both feeds beyond the tracker's cursors and returns the
holes they declare, appending them to `tracker.declared`.
"""
function declare!(tracker::GapTracker)
    run = tracker.run
    g = run.geometry
    fresh = Hole[]
    events = arrival_events(run; after = tracker.rx_cursor)
    for e in events
        e.event in (:lost, :pruned) || continue
        rows = batch_rows(run, e.event === :lost ? "lost" : "ground", e.batch)
        push!(
            fresh,
            Hole(
                e.event,
                e.batch,
                rows,
                row_time(g, first(rows)),
                row_time(g, last(rows) + 1),
            ),
        )
    end
    tracker.rx_cursor += length(events)
    tx_path = joinpath(run.run_dir, "events_tx.csv")
    if isfile(tx_path)
        table = TelemetryCore.read_table(tx_path)
        if tracker.tx_cursor < nrow(table)
            for r in eachrow(table[(tracker.tx_cursor+1):end, :])
                label = String(r.Batch)
                label in GAP_LABELS || continue
                event = String(r.Event)
                if event == "gap_start"
                    haskey(tracker.open, label) ||
                        (tracker.open[label] = DateTime(r.SimTime))
                elseif event == "gap_end" && haskey(tracker.open, label)
                    start = pop!(tracker.open, label)
                    stop = DateTime(r.SimTime)
                    r1, r2 = time_row(g, start), time_row(g, stop) - 1
                    r2 >= r1 && push!(
                        fresh,
                        Hole(Symbol(lowercase(label)), missing, r1:r2, start, stop),
                    )
                end
            end
            tracker.tx_cursor = nrow(table)
        end
    end
    append!(tracker.declared, fresh)
    return fresh
end

"""
    open_gaps(tracker::GapTracker) -> Dict{String,DateTime}

The generation gaps announced by a `gap_start` row and not yet closed,
label => start instant: rows from that instant on are not being produced.
"""
open_gaps(tracker::GapTracker) = copy(tracker.open)

end # module RunAdapter
