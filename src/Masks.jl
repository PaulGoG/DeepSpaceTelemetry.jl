"""
    Masks

The batch-state products of a run: the replay of every batch's state
(future, onboard, link, ground, lost) from the event logs, the 2D mask
timeline it writes, the batch epoch map, the gap table of the delivered
record, the label-span table of the scenario's labeled intervals, and the
point-wise 0/1 availability expansion of one timeline row.
"""
module Masks

using ..TelemetryCore: TelemetryCore
using ..ChannelEffects
using DataFrames: DataFrame, nrow
using Dates: DateTime, Millisecond

"""
    BatchStates

Alias for the per-snapshot batch-location record shared by the mask generator
and the GIF animation: batch-ID vectors for every (stage × stream) bucket plus
the terminal `lost` bucket.
"""
const BatchStates = NamedTuple{
    (
        :onboard_live,
        :onboard_archive,
        :link_live,
        :link_archive,
        :ground_live,
        :ground_archive,
        :lost,
    ),
    NTuple{7,Vector{Int}},
}

"""
    replay_batch_states(f, run_dir::String, df::DataFrame) -> Int

Streams the exact event-log replay over the metrics frame `df`. For every
row `i`, once the events up to `df.SimTime[i]` are applied, `f(i, codes,
live)` is called with `codes::Vector{Int8}`, the state of every batch
identifier (`0` future, `1` onboard, `2` link, `3` ground, `4` lost), and
`live::BitVector`, whether the batch is live; both are indexed by batch
identifier up to the largest identifier among the events the replay applies
(those not later than the last `SimTime` of `df`), which is returned, and
both are reused between calls, so `f` copies what it keeps. Events of
unparsable batch names (identifier `0`) are ignored. The event ordering and
the per-batch causal rule are those described at
[`reconstruct_batch_states`](@ref).
"""
function replay_batch_states(f, run_dir::String, df::DataFrame)
    tx = TelemetryCore.read_table(joinpath(run_dir, "events_tx.csv"))
    rx_path = joinpath(run_dir, "events_rx.csv")
    rx =
        isfile(rx_path) ? TelemetryCore.read_table(rx_path) :
        DataFrame(SimTime = DateTime[], Batch = String[], Event = String[], Attempt = Int[])

    # Chronological milestone list; the priority index breaks same-timestamp
    # ties in causal order (a batch is generated before it is transmitted,
    # transmitted before it is resolved). State-preserving events (`retry`:
    # the batch stays on the link; `pruned`: delivery already happened) are
    # skipped; unknown event names are tolerated with a warning so a newer
    # run's log never aborts an older toolchain's replay.
    event_rank = Dict("gen" => 1, "tx" => 2, "ingested" => 3, "lost" => 3)
    events = Vector{Tuple{DateTime,Int,String,String}}()
    for r in eachrow(tx)
        # Stream-level rows (outage bounds, event markers) carry no state.
        r.Event in ("gap_start", "gap_end", "marker") && continue
        if !haskey(event_rank, r.Event)
            @warn "[POST] Skipping unknown event \"$(r.Event)\" in events_tx.csv." maxlog =
                1
            continue
        end
        push!(events, (r.SimTime, event_rank[r.Event], String(r.Batch), String(r.Event)))
    end
    for r in eachrow(rx)
        r.Event in ("retry", "pruned") && continue
        if !haskey(event_rank, r.Event)
            @warn "[POST] Skipping unknown event \"$(r.Event)\" in events_rx.csv." maxlog =
                1
            continue
        end
        push!(events, (r.SimTime, event_rank[r.Event], String(r.Batch), String(r.Event)))
    end
    sort!(events, by = e -> (e[1], e[2]))

    # The replay applies a prefix of the sorted events, those not later than
    # the last metrics row; the identifier range is taken over that prefix,
    # which is the column range the mask timeline has always had.
    n_applied = 0
    if nrow(df) > 0
        t_last = maximum(df.SimTime)
        n_applied = count(e -> e[1] <= t_last, events)
    end
    max_id = 0
    for k in 1:n_applied
        max_id = max(max_id, TelemetryCore.batch_id(events[k][3]))
    end

    # Causal stage code (see `reconstruct_batch_states`): a later stage is
    # absorbing, and an earlier-stage event arriving late is dropped.
    stage_code =
        Dict("gen" => Int8(1), "tx" => Int8(2), "ingested" => Int8(3), "lost" => Int8(4))
    codes = zeros(Int8, max_id)
    live = falses(max_id)

    ev_idx = 1
    for i in 1:nrow(df)
        t = df.SimTime[i]
        while ev_idx <= length(events) && events[ev_idx][1] <= t
            (_, _, name, kind) = events[ev_idx]
            ev_idx += 1
            id = TelemetryCore.batch_id(name)
            1 <= id <= max_id || continue
            # Set on every event, which is harmless: a batch keeps its name.
            live[id] = TelemetryCore.is_live_batch(name)
            target = stage_code[kind]
            target > codes[id] && (codes[id] = target)
        end
        f(i, codes, live)
    end
    return max_id
end

# Batch identifiers in state `code`, ascending, restricted to live
# (`stream = true`) or archive (`false`) batches, or of either (`nothing`).
stage_ids(codes, live, code, stream) = [
    id for id in eachindex(codes) if
    codes[id] == code && (stream === nothing || live[id] == stream)
]

"""
    reconstruct_batch_states(run_dir::String, df::DataFrame; rows = 1:nrow(df))

Exact replay of every batch's location from the ground-truth event logs:
the `gen`/`tx` milestones of `events_tx.csv` (emitter) and the
`ingested`/`lost` milestones of `events_rx.csv` (receiver); the
state-preserving `retry` and `pruned` rows are skipped. Returns one
[`BatchStates`](@ref) record per requested `mission_profile.csv` row, in the
order of `rows`, evaluated at that row's `SimTime`; the identifiers of each
bucket are sorted ascending (order within a bucket is not part of the
contract). Each loss is attributed to its batch ID, which gives mask state
`4 = Lost`. Emitter and receiver stamp milestones from separate clock reads,
so recorded timestamps can invert within a batch at high speed-up; the
replay enforces per-batch causal order (`gen` → `tx` → terminal) with later
stages absorbing, keeping every batch's state sequence monotone. Events at
the same instant are applied in causal order. The streaming form, which
keeps no record per row, is [`replay_batch_states`](@ref).
"""
function reconstruct_batch_states(
    run_dir::String,
    df::DataFrame;
    rows::AbstractVector{<:Integer} = 1:nrow(df),
)
    all(in(1:nrow(df)), rows) ||
        throw(ArgumentError("[POST] Requested rows must lie within 1:$(nrow(df))."))
    # Positions in the result of every requested row (a row may repeat).
    slots = Dict{Int,Vector{Int}}()
    for (k, i) in enumerate(rows)
        push!(get!(Vector{Int}, slots, Int(i)), k)
    end
    states = Vector{BatchStates}(undef, length(rows))
    replay_batch_states(run_dir, df) do i, codes, live
        targets = get(slots, i, nothing)
        targets === nothing && return nothing
        for k in targets
            states[k] = (
                onboard_live = stage_ids(codes, live, 1, true),
                onboard_archive = stage_ids(codes, live, 1, false),
                link_live = stage_ids(codes, live, 2, true),
                link_archive = stage_ids(codes, live, 2, false),
                ground_live = stage_ids(codes, live, 3, true),
                ground_archive = stage_ids(codes, live, 3, false),
                lost = stage_ids(codes, live, 4, nothing),
            )
        end
        return nothing
    end
    return states
end

# Runs without `events_tx.csv` (pre-0.9 layouts) cannot be replayed.
function require_event_log(run_dir::String)
    isfile(joinpath(run_dir, "events_tx.csv")) || throw(
        ArgumentError(
            "[POST] events_tx.csv missing in $run_dir — the batch-state replay needs the ground-truth event log; runs without it are not supported.",
        ),
    )
    return nothing
end

"""
    batch_states(run_dir::String, df::DataFrame; rows = 1:nrow(df)) -> Vector{BatchStates}

Batch-location history of a run: the exact event-log replay
([`reconstruct_batch_states`](@ref)) over the metrics frame `df`, for the
metrics rows `rows`. Runs without `events_tx.csv` (pre-0.9 layouts) are not
supported and raise an `ArgumentError`.
"""
function batch_states(
    run_dir::String,
    df::DataFrame;
    rows::AbstractVector{<:Integer} = 1:nrow(df),
)
    require_event_log(run_dir)
    return reconstruct_batch_states(run_dir, df; rows = rows)
end

"""
    generate_telemetry_masks(run_dir::String)

Writes the replay of the LIFO/FIFO transmission state machine
([`batch_states`](@ref)) as the 2D matrix `telemetry_mask_timeline.csv`:
rows are time steps, columns the `Batch_ID`s, entries the batch's location
(0=Future, 1=Onboard, 2=Link, 3=Ground, 4=Lost). The rows are streamed from
[`replay_batch_states`](@ref) to disk, so the matrix is never held in memory.
Also writes the batch-epoch map `masks/batch_epochs.csv`; returns without
output, with a warning, when `mission_profile.csv` is absent.
"""
function generate_telemetry_masks(run_dir::String)
    log_path = joinpath(run_dir, "mission_profile.csv")
    if !isfile(log_path)
        @warn "[POST] mission_profile.csv missing in $run_dir — the receiver produced no metrics (component never ran?); skipping this product."
        return
    end

    df = TelemetryCore.normalize_profile!(TelemetryCore.read_table(log_path))
    if isempty(df)
        return
    end

    require_event_log(run_dir)
    mask_path = TelemetryCore.mask_timeline_path(run_dir)
    # The header needs the largest batch ID, known only once the replay has
    # run, so the rows go to a scratch file first. The text is the one the
    # CSV writer produced for the former table: instants in the form of
    # `timestamp_text`, the state codes as single digits, no quoting, `\n`
    # line ends. Columns run over every ID up to the true maximum, not the
    # batch count: the ID space may carry holes (truncated logs,
    # hand-assembled or reconciled run directories).
    mktempdir() do scratch
        body_path = joinpath(scratch, "rows.csv")
        max_id = open(body_path, "w") do body
            line = UInt8[]
            replay_batch_states(run_dir, df) do i, codes, _
                print(body, coalesce(TelemetryCore.timestamp_text(df.SimTime[i]), ""))
                resize!(line, 2 * length(codes) + 1)
                for (k, c) in enumerate(codes)
                    line[2k-1] = UInt8(',')
                    line[2k] = UInt8('0') + UInt8(c)
                end
                line[end] = UInt8('\n')
                write(body, line)
                return nothing
            end
        end

        backup = TelemetryCore.backup_existing(mask_path)
        backup !== nothing && @info "[SAFESAVE] Existing file backed up to: $backup"
        open(mask_path, "w") do out
            print(out, "SimTime")
            for id in 1:max_id
                print(out, ",Batch_", id)
            end
            print(out, '\n')
            chunk = Vector{UInt8}(undef, 1 << 16)
            open(body_path) do body
                while !eof(body)
                    n = readbytes!(body, chunk)
                    write(out, view(chunk, 1:n))
                end
            end
        end
    end
    @info "[POST] Saved 2D telemetry data masks to: $(relpath(mask_path, run_dir))"

    # Batch → epoch sidecar: the point-wise mask's row-index contract assumes
    # a contiguous series, which generation gaps break; this map lets
    # consumers re-anchor batch rows on the mission timeline and the payload.
    # `GenSimTime` is the finalization (transmittable) instant from the event
    # log; `ContentEpoch` and `PayloadRow` are the first-sample timestamp and
    # payload row from each batch's metadata (missing for batches written
    # before those keys existed).
    tx_path = joinpath(run_dir, "events_tx.csv")
    if isfile(tx_path)
        tx_events = TelemetryCore.read_table(tx_path)
        gens = tx_events[tx_events.Event .== "gen", :]
        if !isempty(gens)
            content = TelemetryCore.batch_content_epochs(run_dir)
            rows = TelemetryCore.batch_payload_rows(run_dir)
            epochs = DataFrame(
                Batch = gens.Batch,
                GenSimTime = gens.SimTime,
                ContentEpoch = [get(content, String(b), missing) for b in gens.Batch],
                PayloadRow = [get(rows, String(b), missing) for b in gens.Batch],
            )
            TelemetryCore.safe_csv_write(
                joinpath(run_dir, "masks", "batch_epochs.csv"),
                epochs,
            )
        end
    end
end

"""
    GAP_CAUSES

The values of the `Cause` column of [`gap_table`](@ref): `lost` (retry
budget exhausted), `pruned` (payload removed by the retention custodian),
`undelivered` (generated, on board or on the link at run end), `stream`
(emitter outage), `scheduled` (a scheduled generation gap), `recorder`
(on-board recorder overflow), and `not_generated` (an external record not
exhausted by run end).
"""
const GAP_CAUSES =
    ("lost", "pruned", "undelivered", "stream", "scheduled", "recorder", "not_generated")

"""
    gap_table(run_dir::String) -> DataFrame

Every hole of the delivered record of a run, as declared intervals with
their cause: columns `Cause` ([`GAP_CAUSES`](@ref)), `Batch` (the batch of
a batch-level hole, `missing` for a generation gap or the unreached tail),
`RowFirst` and `RowLast` (payload rows, inclusive), and `ContentStart`,
`ContentEnd` (the content interval `[ContentStart, ContentEnd)`), sorted
by `RowFirst`. Batch rows come from the `payload_row` stamp of the batch
metadata, or from the batch index when the stamp is absent (runs before
2.1.0, which have no gap rows either); generation gaps from the
`gap_start` / `gap_end` pairs of `events_tx.csv`, a gap left open at run
end closed at the mission's end; the unreached tail from
`external_data_rows` of the snapshot. The rows of the table and the rows
no delivered batch covers are the same set. On a finished run the
declared-hole feed `holes.csv`, settled by [`settle_hole_feed!`](@ref),
holds the same holes with the instant each was declared at.
"""
function gap_table(run_dir::String)
    cfg = TelemetryCore.load_run_config(run_dir)
    physics = TelemetryCore.physics_settings(cfg)
    provenance = get(cfg, "provenance", Dict{String,Any}())
    fs = physics.sample_rate
    points_per_batch = TelemetryCore.points_per_batch(physics)
    origin = TelemetryCore.payload_origin(cfg)
    t_end = TelemetryCore.mission_end(cfg)
    time_of(r::Integer) = TelemetryCore.payload_row_time(origin, fs, r)

    stamped = TelemetryCore.batch_payload_rows(run_dir)
    rows_of(name) =
        TelemetryCore.batch_hole_rows(get(stamped, name, nothing), name, points_per_batch)
    tx_path = joinpath(run_dir, "events_tx.csv")
    rx_path = joinpath(run_dir, "events_rx.csv")
    empty_rx() =
        DataFrame(SimTime = DateTime[], Batch = String[], Event = String[], Attempt = Int[])
    tx =
        isfile(tx_path) ? TelemetryCore.read_table(tx_path) :
        DataFrame(SimTime = DateTime[], Batch = String[], Event = String[])
    rx = isfile(rx_path) ? TelemetryCore.read_table(rx_path) : empty_rx()

    causes, batches, firsts, lasts = String[], Union{Missing,String}[], Int[], Int[]
    function hole!(cause, batch, r1, r2)
        r2 >= r1 || return
        push!(causes, cause)
        push!(batches, batch)
        push!(firsts, r1)
        push!(lasts, r2)
        return nothing
    end
    batch_hole!(cause, name) = hole!(cause, name, first(rows_of(name)), last(rows_of(name)))
    generated = Set(String.(tx.Batch[tx.Event .== "gen"]))
    delivered = Set(String.(rx.Batch[rx.Event .== "ingested"]))
    lost = Set(String.(rx.Batch[rx.Event .== "lost"]))
    pruned = Set(String.(rx.Batch[rx.Event .== "pruned"]))
    foreach(name -> batch_hole!("lost", name), lost)
    foreach(name -> batch_hole!("pruned", name), pruned)
    for name in generated
        name in delivered || name in lost || batch_hole!("undelivered", name)
    end
    # Generation gaps: one open gap per label at a time, closed by the next
    # gap_end of that label or at the mission's end.
    for label in ("STREAM", "SCHEDULED", "RECORDER")
        open_at = nothing
        for r in eachrow(tx[tx.Batch .== label, :])
            if r.Event == "gap_start"
                open_at === nothing && (open_at = r.SimTime)
            elseif r.Event == "gap_end" && open_at !== nothing
                gap = TelemetryCore.gap_hole_rows(origin, fs, open_at, r.SimTime)
                hole!(lowercase(label), missing, first(gap), last(gap))
                open_at = nothing
            end
        end
        if open_at !== nothing
            gap = TelemetryCore.gap_hole_rows(origin, fs, open_at, t_end)
            hole!(lowercase(label), missing, first(gap), last(gap))
        end
    end
    external_rows = get(provenance, "external_data_rows", nothing)
    if external_rows isa Integer && !isempty(generated)
        last_generated = maximum(last(rows_of(name)) for name in generated)
        last_generated < external_rows &&
            hole!("not_generated", missing, last_generated + 1, Int(external_rows))
    end
    table = DataFrame(
        Cause = causes,
        Batch = batches,
        RowFirst = firsts,
        RowLast = lasts,
        ContentStart = time_of.(firsts),
        ContentEnd = time_of.(lasts .+ 1),
    )
    sort!(table, [:RowFirst, :Cause])
    return table
end

"""
    write_gap_table(run_dir::String) -> String

Writes [`gap_table`](@ref) of a run to `<run_dir>/masks/gaps.csv`
(rotated, never overwritten) and returns the path.
"""
function write_gap_table(run_dir::String)
    path = joinpath(run_dir, "masks", "gaps.csv")
    mkpath(dirname(path))
    table = gap_table(run_dir)
    TelemetryCore.safe_csv_write(path, table)
    @info "[POST] Gap table saved: $(relpath(path, run_dir)) ($(nrow(table)) holes)."
    return path
end

"""
    settle_hole_feed!(run_dir::String) -> Int

Appends to `holes.csv`, the declared-hole feed, every row of
[`gap_table`](@ref) it does not yet hold, with the nominal mission end
(`TelemetryCore.mission_end`) as `DeclaredAt`: the end-of-run causes a feed
cannot announce during the run (`undelivered`, `not_generated`) and a
recorder gap still open at the mission's end. On a finished run the feed and
`masks/gaps.csv` then hold the same holes. Idempotent: a second call appends
nothing. Returns the number of rows appended.
"""
function settle_hole_feed!(run_dir::String)
    table = gap_table(run_dir)
    feed = TelemetryCore.hole_feed(run_dir)
    held = TelemetryCore.read_hole_feed(run_dir)
    key(cause, batch, r1, r2) =
        (String(cause), ismissing(batch) ? "" : String(batch), Int(r1), Int(r2))
    present = Set{Tuple{String,String,Int,Int}}(
        key(r.Cause, r.Batch, r.RowFirst, r.RowLast) for r in eachrow(held)
    )
    declared_at = TelemetryCore.mission_end(TelemetryCore.load_run_config(run_dir))
    n = 0
    for r in eachrow(table)
        key(r.Cause, r.Batch, r.RowFirst, r.RowLast) in present && continue
        TelemetryCore.declare_hole!(
            feed,
            declared_at,
            r.Cause,
            r.Batch,
            Int(r.RowFirst):Int(r.RowLast),
        ) && (n += 1)
    end
    @info "[POST] Hole feed settled: $n rows appended."
    return n
end

"""
    LABEL_SPAN_CLASSES

The values of the `Class` column of [`label_span_table`](@ref):
`initial_downtime` (the blind spot before the mission epoch), `label` (a
`[[labels]]` span of the scenario), `blackout` and `recovery` (the two
phases of a link disruption), `generation_gap` (a scheduled generation
gap as configured), `contact` (a scheduled contact pass), and
`low_latency` (a low-latency period, scheduled or triggered by a marker).
"""
const LABEL_SPAN_CLASSES = (
    "initial_downtime",
    "label",
    "blackout",
    "recovery",
    "generation_gap",
    "contact",
    "low_latency",
)

"""
    label_span_table(run_dir::String) -> DataFrame

Every labeled interval the scenario of a run declares, on the payload grid
of [`gap_table`](@ref): columns `Class` ([`LABEL_SPAN_CLASSES`](@ref)),
`Type`, `Label`, `RowFirst`, `RowLast` (payload rows, inclusive),
`ContentStart`, `ContentEnd` (the interval `[ContentStart, ContentEnd)`),
sorted by `RowFirst`, `RowLast`, `Class`, `Label`. The table is derived
from the run's configuration snapshot alone. Time intervals are taken as
half-open and clipped to the mission record, rows `1` to the row before
the mission end; `[[labels]]` spans keep their configured rows verbatim.
`Type` is the disruption `type` for `blackout`, `recovery`, and
`generation_gap`, `pass` for a contact, `triggered` or `scheduled` for a
low-latency period, and empty otherwise; `Label` is the configured label.
A generation gap is the configured span from `start_day` over
`duration_hours`; the realized gap of `masks/gaps.csv` may differ from it
by the snap of the emitter to the segment grid. Intervals that cover no
payload row are omitted.
"""
function label_span_table(run_dir::String)
    cfg = TelemetryCore.load_run_config(run_dir)
    physics = TelemetryCore.physics_settings(cfg)
    fs = physics.sample_rate
    origin = TelemetryCore.payload_origin(cfg)
    start_sim = TelemetryCore.mission_epoch(cfg)
    t_end = TelemetryCore.mission_end(cfg)
    time_of(r::Integer) = TelemetryCore.payload_row_time(origin, fs, r)
    row_of(t::DateTime) = TelemetryCore.payload_time_row(origin, fs, t)
    row_end = row_of(t_end) - 1

    classes, types, labels, firsts, lasts = String[], String[], String[], Int[], Int[]
    function span!(class, type, label, r1, r2)
        r2 >= r1 || return nothing
        push!(classes, class)
        push!(types, type)
        push!(labels, label)
        push!(firsts, r1)
        push!(lasts, r2)
        return nothing
    end
    time_span!(class, type, label, start::DateTime, stop::DateTime) =
        span!(class, type, label, max(row_of(start), 1), min(row_of(stop) - 1, row_end))

    time_span!("initial_downtime", "", "", origin, start_sim)
    for s in TelemetryCore.label_settings(cfg)
        span!("label", "", s.label, s.row_first, s.row_last)
    end
    for ev in ChannelEffects.build_disruption_timeline(cfg, start_sim).events
        time_span!("blackout", ev.type, ev.label, ev.start_time, ev.blackout_end)
        ev.recovery_end > ev.blackout_end &&
            time_span!("recovery", ev.type, ev.label, ev.blackout_end, ev.recovery_end)
    end
    for ev in TelemetryCore.disruption_event_settings(cfg)
        ev.affects == "generation" || continue
        t0 = start_sim + Millisecond(round(Int, ev.start_day * TelemetryCore.MS_PER_DAY))
        t1 = t0 + Millisecond(round(Int, ev.duration_hours * TelemetryCore.MS_PER_HOUR))
        time_span!("generation_gap", ev.type, ev.label, t0, t1)
    end
    marker_labels = Set{String}(m.label for m in TelemetryCore.event_marker_settings(cfg))
    for w in
        TelemetryCore.contact_windows(TelemetryCore.visibility_model(cfg), origin, t_end)
        if w.low_latency
            type = w.label in marker_labels ? "triggered" : "scheduled"
            time_span!("low_latency", type, w.label, w.start, w.stop)
        else
            time_span!("contact", "pass", w.label, w.start, w.stop)
        end
    end
    table = DataFrame(
        Class = classes,
        Type = types,
        Label = labels,
        RowFirst = firsts,
        RowLast = lasts,
        ContentStart = DateTime[time_of(r) for r in firsts],
        ContentEnd = DateTime[time_of(r + 1) for r in lasts],
    )
    sort!(table, [:RowFirst, :RowLast, :Class, :Label])
    return table
end

"""
    write_label_spans(run_dir::String) -> String

Writes [`label_span_table`](@ref) of a run to `<run_dir>/label_spans.csv`
(rotated, never overwritten) and returns the path. The file is written
even when the table is empty, as a header without rows.
"""
function write_label_spans(run_dir::String)
    path = joinpath(run_dir, "label_spans.csv")
    table = label_span_table(run_dir)
    TelemetryCore.safe_csv_write(path, table)
    @info "[POST] Label spans saved: label_spans.csv ($(nrow(table)) spans)."
    return path
end

"""
    expand_pointwise_mask(run_dir, total_points, event_idx, output_path) -> Int

Expands one row of `masks/telemetry_mask_timeline.csv` (`event_idx`; `-1`
selects the final snapshot) into a point-wise 0/1 availability array of
`total_points` samples, 1 where the owning batch is on the ground (state 3)
and 0 in states 0 (future), 1 (onboard), 2 (link), and 4 (lost), and writes
it as `Time_Index, Ground_Available` to `output_path` (with `safe_csv_write`
rotation). Batch `k` owns the samples from `(k − 1) · points_per_batch + 1`,
points per batch following the run's own configuration snapshot. Returns the
number of available points; throws an `ArgumentError` when the mask file is
absent or `event_idx` lies outside the timeline.
"""
function expand_pointwise_mask(
    run_dir::String,
    total_points::Int,
    event_idx::Int,
    output_path::String,
)
    mask_path = TelemetryCore.mask_timeline_path(run_dir)
    isfile(mask_path) ||
        throw(ArgumentError("[POST] Telemetry mask not found at: $mask_path"))
    physics = TelemetryCore.physics_settings(TelemetryCore.load_run_config(run_dir))
    points_per_batch = TelemetryCore.points_per_batch(physics)
    mask_df = TelemetryCore.read_mask_timeline(run_dir)
    target_idx = event_idx == -1 ? nrow(mask_df) : event_idx
    1 <= target_idx <= nrow(mask_df) || throw(
        ArgumentError(
            "[POST] Event index $target_idx is out of bounds: the timeline has $(nrow(mask_df)) events.",
        ),
    )
    event_row = mask_df[target_idx, :]
    @info "[POST] Expanding mask row $target_idx ($(event_row.SimTime)) to $total_points points ($points_per_batch per batch)."
    point_mask = zeros(Int8, total_points)
    for (batch_index, status) in enumerate(Vector(event_row[2:end]))
        status == 3 || continue
        start_idx = (batch_index - 1) * points_per_batch + 1
        start_idx <= total_points || continue
        point_mask[start_idx:min(start_idx+points_per_batch-1, total_points)] .= 1
    end
    TelemetryCore.safe_csv_write(
        output_path,
        DataFrame(Time_Index = 1:total_points, Ground_Available = point_mask),
    )
    available = count(==(1), point_mask)
    @info "[POST] Point-wise mask saved to $output_path: $available of $total_points points available on the ground ($(round(100 * available / total_points, digits = 2)) %)."
    return available
end

end # module Masks
