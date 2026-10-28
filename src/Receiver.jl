"""
    Receiver

The ground-station loop: bandwidth-paced ingestion with stochastic loss
and retransmission, the retention custodian, and the metrics and
`events_rx.csv` recording. Re-entrant: a restarted receiver reseeds retry
and custodial state from the event log. The derived products live in
[`Masks`](@ref) and [`MissionFigures`](@ref).
"""
module Receiver

using ..TelemetryCore: TelemetryCore
using ..ChannelEffects
using Dates: DateTime, Millisecond, now

"""
    delivered_payload_queue(run_dir::String, ground_path::String)
        -> Vector{Tuple{DateTime,String,Int}}

Materializes the retention custodian's pruning queue from the run's ground
census and `events_rx.csv`: delivered (`ingested`) batches whose payload has
not been `pruned`, oldest-ingested first, each with its current `seg_*.csv`
payload size in bytes. Consulted at startup for the payload tally and lazily
on watermark breach, so the in-memory queue stays empty outside breach
episodes.
"""
function delivered_payload_queue(run_dir::String, ground_path::String)
    rx_log_path = joinpath(run_dir, "events_rx.csv")
    isfile(rx_log_path) || return Tuple{DateTime,String,Int}[]
    rx_hist = TelemetryCore.read_table(rx_log_path)
    isempty(rx_hist) && return Tuple{DateTime,String,Int}[]
    ingested_t = Dict(
        String(r.Batch) => r.SimTime for r in eachrow(rx_hist) if r.Event == "ingested"
    )
    pruned_set = Set(String(r.Batch) for r in eachrow(rx_hist) if r.Event == "pruned")
    ground_names = filter(f -> isdir(joinpath(ground_path, f)), readdir(ground_path))
    survivors = sort!(
        [b for b in ground_names if haskey(ingested_t, b) && !(b in pruned_set)];
        by = b -> ingested_t[b],
    )
    queue = Tuple{DateTime,String,Int}[]
    for b in survivors
        push!(queue, (ingested_t[b], b, payload_bytes(joinpath(ground_path, b))))
    end
    return queue
end

# --- Service pacing ---
"""
    ServicePacer

The running completion instant `sim` of the receiver's download slot on the
mission timeline of the [`TelemetryCore.TickClock`](@ref). Consecutive slots
are chained against it ([`serve_slot!`](@ref)), so back-to-back transfers
follow one another at the modeled rate.
"""
mutable struct ServicePacer
    sim::DateTime
end

"""
    serve_slot!(pacer::ServicePacer, clock::TelemetryCore.TickClock, slot_sim_sec::Real)

Waits out one download slot of `slot_sim_sec` mission seconds. The slot
starts when the previous one completed, or now after an idle stretch of at
least one slot, and the task parks on the tick clock until it ends
([`TelemetryCore.wait_until!`](@ref)), so the slot elapses as mission time
exactly.
"""
function serve_slot!(
    pacer::ServicePacer,
    clock::TelemetryCore.TickClock,
    slot_sim_sec::Real,
)
    slot = Millisecond(round(Int, slot_sim_sec * 1000))
    t = clock.now_sim
    pacer.sim = (t - pacer.sim >= slot ? t : pacer.sim) + slot
    TelemetryCore.wait_until!(clock, pacer.sim; priority = TelemetryCore.RECEIVER_PRIORITY)
    return nothing
end

"""
    idle_wait!(clock::TelemetryCore.TickClock, link_path::String)

The receiver's wait while nothing is on the link: a park on the tick clock
until another component has run ([`TelemetryCore.wait_for_change!`](@ref)),
since the link changes only when the emitter does.
"""
idle_wait!(clock::TelemetryCore.TickClock, ::String) =
    TelemetryCore.wait_for_change!(clock; priority = TelemetryCore.RECEIVER_PRIORITY)

# --- Receiver state ---
"""
    payload_bytes(batch_dir::String) -> Int

Size of the `seg_*.csv` payload files of a batch directory [bytes].
"""
payload_bytes(batch_dir::String) = sum(
    f -> startswith(f, "seg_") ? Int(filesize(joinpath(batch_dir, f))) : 0,
    readdir(batch_dir);
    init = 0,
)

"""
    reattach_state(run_dir, link_path, ground_names, clock, retention) -> NamedTuple

Retry and custodial state of a receiver attaching to a run, from its
`events_rx.csv`: `retry_counts`, the failed attempts of each batch still on
the link; `total_retries`, the run's `retry` rows; and `payload_bytes`, the
delivered-payload tally (zero unless `retention.enabled`). A restarted
receiver must not grant fresh retry budgets to in-flight batches nor forget
custodial state. Batches of `ground_names` without an `ingested` record
witness a crash between the delivery move and the log append; their record
is synthesized at the current mission instant, as the delivery time is
unrecoverable, so masks, custodian, and consumers agree the batch is
delivered. A run without events yields the empty state.
"""
function reattach_state(
    run_dir::String,
    link_path::String,
    ground_names::Vector{String},
    clock::TelemetryCore.TickClock,
    retention::TelemetryCore.RetentionPolicy,
)
    retry_counts = Dict{String,Int}()
    state = (retry_counts = retry_counts, total_retries = 0, payload_bytes = 0)
    rx_log_path = joinpath(run_dir, "events_rx.csv")
    isfile(rx_log_path) || return state
    rx_hist = TelemetryCore.read_table(rx_log_path)
    isempty(rx_hist) && return state
    pending = Set(filter(f -> isdir(joinpath(link_path, f)), readdir(link_path)))
    for r in eachrow(rx_hist)
        r.Event == "retry" &&
            r.Batch in pending &&
            (retry_counts[r.Batch] = get(retry_counts, r.Batch, 0) + 1)
    end
    ingested_t = Dict(
        String(r.Batch) => r.SimTime for r in eachrow(rx_hist) if r.Event == "ingested"
    )
    unrecorded = sort!(collect(setdiff(Set(ground_names), keys(ingested_t))))
    if !isempty(unrecorded)
        reconcile_t = TelemetryCore.get_current_sim_time(clock)
        for b in unrecorded
            TelemetryCore.log_rx_event(run_dir, reconcile_t, b, "ingested", 0)
        end
        @warn "[RECEIVER] Re-attach: synthesized ingested records at $reconcile_t for $(length(unrecorded)) batches present in ground/ without a delivery record (crash window between delivery and logging)." batches =
            first(unrecorded, min(5, length(unrecorded)))
    end
    # Tally only: the prune queue is built on breach.
    tally =
        retention.enabled ?
        sum(
            entry -> entry[3],
            delivered_payload_queue(run_dir, joinpath(run_dir, "ground"));
            init = 0,
        ) : 0
    return (
        retry_counts = retry_counts,
        total_retries = count(==("retry"), rx_hist.Event),
        payload_bytes = tally,
    )
end

"""
    RetentionCustodian

State of the retention custodian: `queue`, the delivered batches as
`(ingest instant, name, payload bytes)`, oldest-ingested first,
materialized on watermark breach ([`delivered_payload_queue`](@ref)) and
empty between breach episodes; and `payload_bytes`, the running tally of
prunable payload compared with the watermark.
"""
mutable struct RetentionCustodian
    const queue::Vector{Tuple{DateTime,String,Int}}
    payload_bytes::Int
end

"""
    custodian_step!(custodian, retention, run_dir, sim_t; hole_feed = nothing)

One pass of the retention custodian at `sim_t`: while the tally exceeds
`retention.watermark_bytes`, the oldest-ingested batch at least
`retention.grace` past its ingestion loses its payload. Each prune appends
the `pruned` event row and declares the hole first, then writes the
`PRUNED` marker, then deletes the payload, so a consumer never sees a
payload-less batch without its `pruned` row. An I/O failure is logged and
leaves the tally unchanged, as the files are still on disk; the batch is
not re-queued.
"""
function custodian_step!(
    custodian::RetentionCustodian,
    retention::TelemetryCore.RetentionPolicy,
    run_dir::String,
    sim_t::DateTime;
    hole_feed::Union{TelemetryCore.HoleFeed,Nothing} = nothing,
)
    (retention.enabled && custodian.payload_bytes > retention.watermark_bytes) ||
        return nothing
    ground_path = joinpath(run_dir, "ground")
    queue = custodian.queue
    # Refreshed when exhausted mid-breach.
    isempty(queue) && append!(queue, delivered_payload_queue(run_dir, ground_path))
    while custodian.payload_bytes > retention.watermark_bytes &&
          !isempty(queue) &&
          (sim_t - queue[1][1]) >= retention.grace
        (ingest_t, pruned_name, batch_bytes) = popfirst!(queue)
        batch_dir = joinpath(ground_path, pruned_name)
        try
            TelemetryCore.log_rx_event(run_dir, sim_t, pruned_name, "pruned", 0)
            hole_feed === nothing ||
                TelemetryCore.declare_batch_hole!(hole_feed, sim_t, "pruned", batch_dir)
            touch(joinpath(batch_dir, "PRUNED"))
            for f in readdir(batch_dir)
                startswith(f, "seg_") && rm(joinpath(batch_dir, f); force = true)
            end
            @info "[RECEIVER] Retention: pruned payload of $pruned_name (ingested $ingest_t)"
            custodian.payload_bytes -= batch_bytes
        catch e
            e isa Union{Base.IOError,SystemError} || rethrow()
            @error "[RECEIVER] Retention pruning failed for $pruned_name — continuing." exception =
                e
        end
    end
    return nothing
end

"""
    status_panel_text(link, sim_t, nominal_factor, disruption_scale, hours_elapsed,
                      ground_count, lost_count, total_retries) -> String

The clear-screen console status panel of the receiver: mission day, link
state (dormant, active, or the active disruption with its recovery level),
and the ground and lost tallies.
"""
function status_panel_text(
    link::ChannelEffects.LinkModel,
    sim_t::DateTime,
    nominal_factor::Float64,
    disruption_scale::Float64,
    hours_elapsed::Float64,
    ground_count::Int,
    lost_count::Int,
    total_retries::Int,
)
    bandwidth_pct = nominal_factor * disruption_scale * 100
    status_text = if disruption_scale < 1.0 && nominal_factor > 0.0
        ev_label = ChannelEffects.active_disruption_label(link.disruptions, sim_t)
        ev_name = isempty(ev_label) ? "DISRUPTION" : uppercase(ev_label)
        disruption_scale == 0.0 ? "$ev_name (Link down)" :
        "$ev_name RECOVERY (Link: $(round(bandwidth_pct, digits=1))%)"
    elseif nominal_factor * disruption_scale > 0.0
        "ACTIVE (Link: $(round(bandwidth_pct, digits=1))%)"
    else
        "DORMANT (Out of window)"
    end
    rule = "="^55 * "\n"
    return "\e[H\e[J" *
           rule *
           lpad("DEEP-SPACE TELEMETRY DASHBOARD", 42) *
           "\n" *
           rule *
           rpad("Mission Day:", 20) *
           "$(round(hours_elapsed / 24.0, digits=2))\n" *
           rpad("Current Status:", 20) *
           "$status_text\n" *
           rpad("Ground total:", 20) *
           "$ground_count received data batches\n" *
           rpad("Lost Batches:", 20) *
           "$lost_count ($total_retries failed transfers)\n" *
           rule
end

# --- Receiver main loop ---
"""
    run_receiver(clock, link, run_dir; ...)

The ground-station loop: serves the batches on `<run_dir>/link/`, each
transfer taking `batch_transfer_sec` divided by the effective link capacity
(visibility profile × disruption factor), draws one loss realization from
`loss_model` per transfer attempt, and moves delivered batches to `ground/`
and retry-exhausted ones to `lost/`. Every milestone is appended to
`events_rx.csv`, from which the post-processing reconstructs the run
exactly. `run_dir` is the absolute path of the run directory.

`clock` is the [`TelemetryCore.TickClock`](@ref) of the mission, paced or
not: in wall mode the driver ([`TelemetryCore.run_ticks!`](@ref)) holds each
wakeup back to its wall instant, which changes when the loop runs but not
what it records. Every wait parks the task on the clock, and the loop ends
at the horizon, on the stop flag, or on the `HALT` sentinel
([`TelemetryCore.loop_should_stop`](@ref)).

A lost transfer leaves the batch on the link; its retransmission is served
no earlier than `round_trip_light_time_sec` after the loss was detected
(deferred negative acknowledgment), while the other in-flight batches keep
being served. A batch whose transfer fails `max_retries + 1` times moves to
`lost/`, data preserved, which frees its slot in the emitter's transmission
window (in-flight occupancy is the `link/` listing). A re-attaching receiver
reseeds retry and custodial state from the event log
([`reattach_state`](@ref)).

With `retention.enabled` the loop also runs the retention custodian
([`custodian_step!`](@ref)): while the delivered-payload tally exceeds
`watermark_bytes`, the oldest-ingested batches, once at least `grace` of
mission time past their ingestion, lose their `seg_*.csv` payload files,
keep `metadata.json`, gain a `PRUNED` marker, and are recorded as `pruned`
in `events_rx.csv`. Event logs, metrics, masks, and `lost/` are not pruned.

# Keyword arguments

  - `orig_stdout`: stream receiving the console status panel.
  - `status_panel`: render the clear-screen console status panel
    ([`status_panel_text`](@ref)) to `orig_stdout` on every loop iteration;
    off by default, set by the supervisor from
    `dashboard.receiver_status_panel`.
  - `batch_transfer_sec`: transfer time of one batch at full link capacity
    [mission s] (`telemetry_settings(cfg).nominal_batch_transfer_sec`).
  - `loss_model`: stochastic packet-loss channel (`ChannelEffects.LossModel`).
  - `max_retries`: retransmissions allowed per batch; `0` moves a batch to
    `lost/` at its first failed transfer.
  - `retention`: the custodian's [`TelemetryCore.RetentionPolicy`](@ref).
  - `stop`: cooperative stop flag raised by the supervisor.
  - `min_link_factor`: capacity floor below which no transfer is attempted.
  - `round_trip_light_time_sec`: earliest retransmission delay after a
    detected loss [mission s]; `0.0` retries immediately.
  - `hole_feed`: the declared-hole feed the receiver appends its lost and
    pruned batches to, `nothing` for none.
  - `onboard_count`: the emitter's count of batches on board
    (`Emitter.run_emitter`), read for the metrics; `nothing` lists
    `onboard/` on every iteration instead.
"""
function run_receiver(
    clock::TelemetryCore.TickClock,
    link::ChannelEffects.LinkModel,
    run_dir::String;
    orig_stdout::IO = stdout,
    status_panel::Bool = false,
    batch_transfer_sec::Float64 = 180.0,
    loss_model::ChannelEffects.LossModel = ChannelEffects.NoLoss(),
    max_retries::Int = 3,
    retention::TelemetryCore.RetentionPolicy = TelemetryCore.retention_settings(
        Dict{String,Any}(),
    ),
    stop::Union{Threads.Atomic{Bool},Nothing} = nothing,
    min_link_factor::Float64 = 0.05,
    round_trip_light_time_sec::Float64 = 0.0,
    hole_feed::Union{TelemetryCore.HoleFeed,Nothing} = nothing,
    onboard_count::Union{Threads.Atomic{Int},Nothing} = nothing,
)
    TelemetryCore.checked_run_dir(run_dir)
    link_path = joinpath(run_dir, "link")
    onboard_path = joinpath(run_dir, "onboard")
    ground_path = joinpath(run_dir, "ground")
    lost_path = joinpath(run_dir, "lost")
    foreach(mkpath, (link_path, onboard_path, ground_path, lost_path)) # idempotent

    halt_path = joinpath(run_dir, "HALT")

    last_onboard = -1
    last_link = -1
    last_ground = -1
    last_lost = -1
    last_bw = -1.0

    # Ground and lost counters are receiver-owned (only this loop moves batches
    # into those directories), so they are tracked incrementally after a single
    # startup census: a per-tick readdir over ground/ is O(archive size) and
    # measurably throttles the ingest rate on long missions. The on-board
    # count comes from the emitter for the same reason.
    ground_seed = filter(f -> isdir(joinpath(ground_path, f)), readdir(ground_path))
    ground_live = count(TelemetryCore.is_live_batch, ground_seed)
    ground_arch = count(TelemetryCore.is_archive_batch, ground_seed)
    lost_count = length(filter(f -> isdir(joinpath(lost_path, f)), readdir(lost_path)))

    state = reattach_state(run_dir, link_path, ground_seed, clock, retention)
    retry_counts = state.retry_counts # failed attempts per in-flight batch
    total_retries = state.total_retries
    custodian = RetentionCustodian(Tuple{DateTime,String,Int}[], state.payload_bytes)
    # Deferred negative acknowledgment: a lost transfer is detected on the
    # ground when it completes, and its retransmission cannot be served before
    # one round-trip light time later. Not persisted across a re-attach (a
    # restarted receiver may retry immediately).
    retry_after = Dict{String,DateTime}()
    round_trip = Millisecond(round(Int, round_trip_light_time_sec * 1000))

    @info "[RECEIVER] Ground-station loop started."

    pacer = ServicePacer(TelemetryCore.get_current_sim_time(clock))

    try
        while !TelemetryCore.loop_should_stop(clock, stop, halt_path, "[RECEIVER]")
            sim_t = TelemetryCore.get_current_sim_time(clock)
            nominal_factor = TelemetryCore.get_bandwidth_factor(link.visibility, sim_t)
            disruption_scale = ChannelEffects.disruption_factor(link.disruptions, sim_t)
            bw_factor = nominal_factor * disruption_scale
            hours_elapsed = (sim_t - clock.start_sim_time).value / TelemetryCore.MS_PER_HOUR
            bandwidth_pct = bw_factor * 100

            onboard =
                onboard_count === nothing ?
                length(
                    filter(f -> isdir(joinpath(onboard_path, f)), readdir(onboard_path)),
                ) : onboard_count[]
            pending_batches = filter(
                f -> TelemetryCore.is_batch_name(f) && isdir(joinpath(link_path, f)),
                readdir(link_path),
            )
            ground_count = ground_live + ground_arch

            if onboard != last_onboard ||
               length(pending_batches) != last_link ||
               ground_count != last_ground ||
               lost_count != last_lost ||
               abs(bandwidth_pct - last_bw) > TelemetryCore.METRICS_BANDWIDTH_HYSTERESIS_PCT
                metrics = TelemetryCore.MissionMetrics(
                    sim_t,
                    now(),
                    hours_elapsed,
                    bandwidth_pct,
                    onboard,
                    length(pending_batches),
                    ground_count,
                    ground_live,
                    ground_arch,
                    nominal_factor * 100,
                    lost_count,
                    total_retries,
                    disruption_scale < 1.0,
                )
                TelemetryCore.save_metrics(run_dir, metrics)

                last_onboard = onboard
                last_link = length(pending_batches)
                last_ground = ground_count
                last_lost = lost_count
                last_bw = bandwidth_pct
            end

            # The grace window is the availability guarantee consumers rely
            # on (docs/src/interfaces.md).
            custodian_step!(custodian, retention, run_dir, sim_t; hole_feed = hole_feed)

            if status_panel
                print(
                    orig_stdout,
                    status_panel_text(
                        link,
                        sim_t,
                        nominal_factor,
                        disruption_scale,
                        hours_elapsed,
                        ground_count,
                        lost_count,
                        total_retries,
                    ),
                )
                flush(orig_stdout)
            end

            # Batches whose retransmission cannot have arrived yet are skipped
            # in favor of the next in-flight batch; the link idles only when
            # every pending batch is waiting for its round trip.
            eligible = filter(f -> get(retry_after, f, sim_t) <= sim_t, pending_batches)

            if !isempty(eligible) && bw_factor > min_link_factor
                # LIVE before ARCH; within LIVE oldest-first (FIFO), within ARCH
                # newest-first (LIFO). Plain lexicographic readdir order would
                # scramble numeric IDs (e.g. batch_29 before batch_31).
                sort!(
                    eligible,
                    by = x -> begin
                        id = TelemetryCore.batch_id(x)
                        TelemetryCore.is_live_batch(x) ? (0, id) : (1, -id)
                    end,
                )
                batch_name = first(eligible)

                # One transfer takes batch_transfer_sec / bw_factor mission
                # seconds; the pacer chains the slots and converts them to
                # the clock in use.
                serve_slot!(pacer, clock, batch_transfer_sec / bw_factor)

                loss_mult =
                    ChannelEffects.disruption_loss_multiplier(link.disruptions, sim_t)
                if ChannelEffects.sample_loss!(loss_model; multiplier = loss_mult)
                    attempts = get(retry_counts, batch_name, 0) + 1
                    retry_counts[batch_name] = attempts
                    total_retries += 1
                    detected_at = TelemetryCore.get_current_sim_time(clock)
                    if attempts > max_retries
                        # Retry budget exhausted: preserve the data in lost/;
                        # leaving link/ frees the emitter's window slot.
                        TelemetryCore.backup_existing_dir(joinpath(lost_path, batch_name))
                        mv(joinpath(link_path, batch_name), joinpath(lost_path, batch_name))
                        delete!(retry_counts, batch_name)
                        delete!(retry_after, batch_name)
                        lost_count += 1
                        TelemetryCore.log_rx_event(
                            run_dir,
                            sim_t,
                            batch_name,
                            "lost",
                            attempts,
                        )
                        hole_feed === nothing || TelemetryCore.declare_batch_hole!(
                            hole_feed,
                            sim_t,
                            "lost",
                            joinpath(lost_path, batch_name),
                        )
                        @warn "[RECEIVER] LOST: $batch_name after $attempts failed transfers @ SimTime: $sim_t"
                    else
                        retry_after[batch_name] = detected_at + round_trip
                        TelemetryCore.log_rx_event(
                            run_dir,
                            sim_t,
                            batch_name,
                            "retry",
                            attempts,
                        )
                        @info "[RECEIVER] Transfer failed ($attempts/$(max_retries + 1)): $batch_name — retrying"
                    end
                else
                    @info "[RECEIVER] Ingesting: $batch_name @ SimTime: $sim_t"
                    @info "[RECEIVER] Bandwidth: $(round(bandwidth_pct))% | Batches buffered: $onboard | Total Data Batches: $ground_count"

                    prior_attempts = get(retry_counts, batch_name, 0)
                    TelemetryCore.backup_existing_dir(joinpath(ground_path, batch_name))
                    mv(joinpath(link_path, batch_name), joinpath(ground_path, batch_name))
                    delete!(retry_counts, batch_name)
                    delete!(retry_after, batch_name)
                    if TelemetryCore.is_live_batch(batch_name)
                        ground_live += 1
                    else
                        ground_arch += 1
                    end
                    TelemetryCore.log_rx_event(
                        run_dir,
                        sim_t,
                        batch_name,
                        "ingested",
                        prior_attempts,
                    )
                    retention.enabled && (
                        custodian.payload_bytes +=
                            payload_bytes(joinpath(ground_path, batch_name))
                    )
                end
            elseif !isempty(pending_batches) && bw_factor > min_link_factor
                # Every in-flight batch awaits its round trip: park until the
                # earliest becomes eligible or another component has run.
                earliest = minimum(get(retry_after, f, sim_t) for f in pending_batches)
                TelemetryCore.wait_until_or_change!(
                    clock,
                    earliest;
                    priority = TelemetryCore.RECEIVER_PRIORITY,
                )
            else
                idle_wait!(clock, link_path)
            end
        end
    finally
        status_panel && println(orig_stdout, "\n")
    end
end

end # module Receiver
