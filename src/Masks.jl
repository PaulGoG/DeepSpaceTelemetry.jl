"""
    Masks

The batch-state products of a run: the replay of every batch's state
(future, onboard, link, ground, lost) from the event logs, the 2D mask
timeline it writes, the batch epoch map, and the point-wise 0/1
availability expansion of one timeline row.
"""
module Masks

using ..TelemetryCore
using CSV: CSV
using DataFrames: DataFrame, nrow
using Dates: DateTime

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
    reconstruct_batch_states(run_dir::String, df::DataFrame)

Exact replay of every batch's location from the ground-truth event logs
(`events_tx.csv`: `gen`/`tx` milestones written by the emitter;
`events_rx.csv`: `ingested`/`lost` milestones written by the receiver — the
state-preserving `retry` events are skipped). Returns one [`BatchStates`](@ref)
record per `mission_profile.csv` row, evaluated at that row's `SimTime`.

Each packet loss is attributed to its exact batch ID, which is what makes
mask state `4 = Lost` possible. Emitter and
receiver stamp milestones from separate clock reads, so recorded timestamps
can invert within a batch at high speed-up; the replay enforces per-batch
causal order (`gen` → `tx` → terminal) with later stages absorbing, keeping
every batch's state sequence monotone.
"""
function reconstruct_batch_states(run_dir::String, df::DataFrame)
    tx = CSV.read(joinpath(run_dir, "events_tx.csv"), DataFrame)
    rx_path = joinpath(run_dir, "events_rx.csv")
    rx =
        isfile(rx_path) ? CSV.read(rx_path, DataFrame) :
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

    # Category vectors plus a batch-ID → (category, index) position map:
    # every event application is O(1) via swap-remove, so the replay stays
    # linear in the event count over a mission. Order within a category is
    # not part of the contract (masks index by batch ID; scatters are
    # unordered).
    category = Dict(
        :onboard_live => Int[],
        :onboard_archive => Int[],
        :link_live => Int[],
        :link_archive => Int[],
        :ground_live => Int[],
        :ground_archive => Int[],
        :lost => Int[],
    )
    position = Dict{Int,Tuple{Symbol,Int}}()

    # Swap-remove `id` from its current category (no-op for an unseen ID,
    # e.g. a truncated log whose `gen` row is missing).
    displace! = id -> begin
        loc = get(position, id, nothing)
        loc === nothing && return nothing
        (cat, idx) = loc
        v = category[cat]
        moved = v[end]
        v[idx] = moved
        position[moved] = (cat, idx)
        pop!(v)
        delete!(position, id)
        return nothing
    end
    # Causal stage rank: emitter and receiver stamp events from separate
    # clock reads, so at high speed-up a batch's `ingested` record can carry
    # an earlier timestamp than its own `tx` record. Per-batch causality
    # (gen < tx < terminal) outranks recorded timestamps: a later-stage
    # placement is absorbing and an earlier-stage event arriving late is
    # dropped.
    stage_rank = Dict(
        :onboard_live => 1,
        :onboard_archive => 1,
        :link_live => 2,
        :link_archive => 2,
        :ground_live => 3,
        :ground_archive => 3,
        :lost => 4,
    )
    # Move `id` into `cat`; self-cleaning, so a duplicated log row can
    # never strand a stale copy in a previous category.
    place! =
        (id, cat) -> begin
            loc = get(position, id, nothing)
            loc !== nothing && stage_rank[loc[1]] >= stage_rank[cat] && return nothing
            displace!(id)
            v = category[cat]
            push!(v, id)
            position[id] = (cat, length(v))
            return nothing
        end

    states = Vector{BatchStates}(undef, 0)
    sizehint!(states, nrow(df))

    ev_idx = 1
    for i in 1:nrow(df)
        t = df.SimTime[i]
        while ev_idx <= length(events) && events[ev_idx][1] <= t
            (_, _, name, kind) = events[ev_idx]
            id = TelemetryCore.batch_id(name)
            is_live = TelemetryCore.is_live_batch(name)
            if kind == "gen"
                place!(id, is_live ? :onboard_live : :onboard_archive)
            elseif kind == "tx"
                place!(id, is_live ? :link_live : :link_archive)
            elseif kind == "ingested"
                place!(id, is_live ? :ground_live : :ground_archive)
            elseif kind == "lost"
                place!(id, :lost)
            end
            ev_idx += 1
        end
        push!(
            states,
            (
                onboard_live = copy(category[:onboard_live]),
                onboard_archive = copy(category[:onboard_archive]),
                link_live = copy(category[:link_live]),
                link_archive = copy(category[:link_archive]),
                ground_live = copy(category[:ground_live]),
                ground_archive = copy(category[:ground_archive]),
                lost = copy(category[:lost]),
            ),
        )
    end
    return states
end

"""
    batch_states(run_dir::String, df::DataFrame) -> Vector{BatchStates}

Batch-location history of a run: the exact event-log replay
([`reconstruct_batch_states`](@ref)) over the metrics frame `df`. Runs
without `events_tx.csv` (pre-0.9 layouts) are not supported and raise an
`ArgumentError`.
"""
function batch_states(run_dir::String, df::DataFrame)
    isfile(joinpath(run_dir, "events_tx.csv")) || throw(
        ArgumentError(
            "[POST] events_tx.csv missing in $run_dir — the batch-state replay needs the ground-truth event log; runs without it are not supported.",
        ),
    )
    return reconstruct_batch_states(run_dir, df)
end

"""
    generate_telemetry_masks(run_dir::String)

A post-processing utility that reconstructs the LIFO/FIFO transmission state
machine from the event logs (see [`batch_states`](@ref)). It outputs a 2D matrix `telemetry_mask_timeline.csv`
where rows are time steps and columns are specific `Batch_ID`s, indicating
their exact physical location (0=Future, 1=Onboard, 2=Link, 3=Ground,
4=Lost).
"""
function generate_telemetry_masks(run_dir::String)
    log_path = joinpath(run_dir, "mission_profile.csv")
    if !isfile(log_path)
        @warn "[POST] mission_profile.csv missing in $run_dir — the receiver produced no metrics (component never ran?); skipping this product."
        return
    end

    df = TelemetryCore.normalize_profile!(CSV.read(log_path, DataFrame))
    if isempty(df)
        return
    end

    states = batch_states(run_dir, df)
    # True maximum batch ID, not the batch count: the ID space may carry
    # holes (truncated logs, hand-assembled or reconciled run directories),
    # and a count-sized matrix would fault on the first such hole.
    max_id_ever =
        isempty(states) ? 0 : maximum(cat -> isempty(cat) ? 0 : maximum(cat), last(states))

    # 0 = Future, 1 = Onboard, 2 = Link, 3 = Ground, 4 = Lost
    mask_matrix = zeros(Int8, nrow(df), max_id_ever)

    for (i, st) in enumerate(states),
        (code, cats) in (
            (Int8(1), (st.onboard_live, st.onboard_archive)),
            (Int8(2), (st.link_live, st.link_archive)),
            (Int8(3), (st.ground_live, st.ground_archive)),
            (Int8(4), (st.lost,)),
        )

        for cat in cats, id in cat
            # Unparsable batch names replay as ID 0 — excluded from the
            # matrix rather than faulting the whole product.
            1 <= id <= max_id_ever && (mask_matrix[i, id] = code)
        end
    end

    mask_df = DataFrame(SimTime = df.SimTime)
    for id in 1:max_id_ever
        mask_df[!, Symbol("Batch_$id")] = mask_matrix[:, id]
    end

    mask_path = TelemetryCore.mask_timeline_path(run_dir)
    TelemetryCore.safe_csv_write(mask_path, mask_df)
    @info "[POST] Saved 2D telemetry data masks to: $(relpath(mask_path, run_dir))"

    # Batch → epoch sidecar: the point-wise mask's row-index contract assumes
    # a contiguous series, which emitter outages break; this map lets
    # consumers re-anchor batch rows on the mission timeline. `GenSimTime` is
    # the finalization (transmittable) instant from the event log;
    # `ContentEpoch` is the first-sample timestamp of the payload from each
    # batch's metadata (missing for batches written before that key existed).
    tx_path = joinpath(run_dir, "events_tx.csv")
    if isfile(tx_path)
        tx_events = CSV.read(tx_path, DataFrame)
        gens = tx_events[tx_events.Event .== "gen", :]
        if !isempty(gens)
            content = TelemetryCore.batch_content_epochs(run_dir)
            epochs = DataFrame(
                Batch = gens.Batch,
                GenSimTime = gens.SimTime,
                ContentEpoch = [get(content, String(b), missing) for b in gens.Batch],
            )
            TelemetryCore.safe_csv_write(
                joinpath(run_dir, "masks", "batch_epochs.csv"),
                epochs,
            )
        end
    end
end

"""
    expand_pointwise_mask(run_dir, total_points, event_idx, output_path) -> Int

Expands one row of `masks/telemetry_mask_timeline.csv` (`event_idx`; `-1`
selects the final snapshot) into a point-wise 0/1 availability array of
`total_points` samples — 1 where the owning batch is on the ground
(state 3); states 0 (future), 1 (onboard), 2 (link), and 4 (lost) stay 0, a
lost batch never becoming available — and writes it as
`Time_Index, Ground_Available` to `output_path` (with `safe_csv_write`
rotation). Points per batch follow the run's own configuration snapshot.
Returns the number of available points; throws an `ArgumentError` when the
mask file is absent or `event_idx` lies outside the timeline.
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
    points_per_batch =
        round(Int, physics.sample_rate * physics.segment_duration_sec * physics.batch_size)
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
