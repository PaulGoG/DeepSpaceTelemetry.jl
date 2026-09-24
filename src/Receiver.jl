"""
    Receiver

The ground-station loop: bandwidth-paced ingestion with stochastic loss
and retransmission, the retention custodian, and the metrics and
`events_rx.csv` recording. Re-entrant: a restarted receiver reseeds retry
and custodial state from the event log. The derived products live in
[`Masks`](@ref) and [`MissionFigures`](@ref).
"""
module Receiver

using ..TelemetryCore
using ..ChannelEffects
using CSV: CSV
using DataFrames: DataFrame
using Dates: DateTime, Millisecond, Second, now
using FileWatching: watch_folder

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
    rx_hist = CSV.read(rx_log_path, DataFrame)
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
        bdir = joinpath(ground_path, b)
        payload = sum(
            f -> startswith(f, "seg_") ? Int(filesize(joinpath(bdir, f))) : 0,
            readdir(bdir);
            init = 0,
        )
        push!(queue, (ingested_t[b], b, payload))
    end
    return queue
end

# --- Receiver Main Loop ---
"""
    run_receiver(clock, link, run_id; ...)

The main ground-station loop. It continually checks the `link/` directory for
incoming data batches, simulates a delay based on the effective link capacity
(visibility profile × disruption factor), draws a stochastic loss realization
per transfer attempt from `loss_model`, moves successful batches to `ground/`
and exhausted ones to `lost/`, and — when `status_panel` is set — renders a
console status panel to `orig_stdout`.

A lost transfer leaves the batch on the link; its retransmission is served
no earlier than one round-trip light time after the loss was detected
(`round_trip_light_time_sec`, deferred negative acknowledgement), while the
other in-flight batches keep being served; after
`max_retries` failed attempts the batch is moved to `lost/` — never deleted —
which frees the emitter's transmission window slot (in-flight occupancy is
the `link/` listing). Every
milestone is appended to `events_rx.csv` for exact post-processing
reconstruction. At startup, a re-attaching receiver reseeds retry and
custodial state from the event log and synthesizes `ingested` records (at the
re-attach instant) for batches delivered to `ground/` whose record was lost
to a crash between the delivery move and the log append.

When `retention.enabled` the loop also runs the retention custodian: once the
delivered-payload tally exceeds `watermark_bytes`, the oldest-ingested batches
beyond the `grace` mission-time guarantee have their `seg_*.csv` payload
files deleted — the batch directory keeps `metadata.json`, gains a `PRUNED`
marker, and a `pruned` event is appended to `events_rx.csv`. Event logs,
metrics, masks, and `lost/` are never pruned. The pruning queue is
materialized lazily on watermark breach ([`delivered_payload_queue`](@ref)).

# Keyword arguments

  - `orig_stdout`: stream receiving the console status panel.
  - `status_panel`: render the clear-screen console status panel (mission
    day, link state, ground and lost tallies) to `orig_stdout` on every
    loop iteration; off by default, the supervisor sets it from
    `dashboard.receiver_status_panel`.
  - `batch_transfer_sec`: transfer time of one batch at full link capacity
    [mission s] (`telemetry_settings(cfg).nominal_batch_transfer_sec`).
  - `loss_model`: stochastic packet-loss channel (`ChannelEffects.LossModel`).
  - `max_retries`: failed attempts before a batch moves to `lost/`.
  - `retention`: the custodian's [`TelemetryCore.RetentionPolicy`](@ref).
  - `deadline`: absolute wall-clock stop shared by both components.
  - `stop`: cooperative stop flag raised by the supervisor.
  - `heartbeat_path`: liveness file touched once per second when set.
  - `min_link_factor`: capacity floor below which no transfer is attempted.
  - `round_trip_light_time_sec`: earliest retransmission delay after a
    detected loss [mission s]; `0.0` retries immediately.
"""
function run_receiver(
    clock::TelemetryCore.SimulationClock,
    link::ChannelEffects.LinkModel,
    run_id::String;
    orig_stdout::IO = stdout,
    status_panel::Bool = false,
    batch_transfer_sec::Float64 = 180.0,
    loss_model::ChannelEffects.LossModel = ChannelEffects.NoLoss(),
    max_retries::Int = 3,
    retention::TelemetryCore.RetentionPolicy = TelemetryCore.retention_settings(
        Dict{String,Any}(),
    ),
    deadline::Union{DateTime,Nothing} = nothing,
    stop::Union{Threads.Atomic{Bool},Nothing} = nothing,
    heartbeat_path::Union{String,Nothing} = nothing,
    min_link_factor::Float64 = 0.05,
    round_trip_light_time_sec::Float64 = 0.0,
)
    run_dir = TelemetryCore.run_directory(run_id)
    link_path = joinpath(run_dir, "link")
    onboard_path = joinpath(run_dir, "onboard")
    ground_path = joinpath(run_dir, "ground")
    lost_path = joinpath(run_dir, "lost")
    foreach(mkpath, (link_path, onboard_path, ground_path, lost_path)) # idempotent

    halt_path = joinpath(run_dir, "HALT")
    last_heartbeat = now() - Second(2)

    last_onboard = -1
    last_link = -1
    last_ground = -1
    last_lost = -1
    last_bw = -1.0

    retry_counts = Dict{String,Int}() # failed attempts per in-flight batch
    # Deferred negative acknowledgement: a lost transfer is detected on the
    # ground when it completes, and its retransmission cannot be served before
    # one round-trip light time later. Not persisted across a re-attach (a
    # restarted receiver may retry immediately).
    retry_after = Dict{String,DateTime}()
    round_trip = Millisecond(round(Int, round_trip_light_time_sec * 1000))
    total_retries = 0

    # Ground and lost counters are receiver-owned (only this loop moves batches
    # into those directories), so they are tracked incrementally after a single
    # startup census: a per-tick readdir over ground/ is O(archive size) and
    # measurably throttles the ingest rate on long missions.
    ground_seed = filter(f -> isdir(joinpath(ground_path, f)), readdir(ground_path))
    ground_live = count(TelemetryCore.is_live_batch, ground_seed)
    ground_arch = count(TelemetryCore.is_archive_batch, ground_seed)
    lost_count = length(filter(f -> isdir(joinpath(lost_path, f)), readdir(lost_path)))

    # Retention custodian state: FIFO of delivered batches (ingest sim-time,
    # name, payload bytes) and the running prunable-payload tally the
    # watermark is compared against.
    prune_queue = Vector{Tuple{DateTime,String,Int}}()
    ground_payload_bytes = 0

    # Re-attach seeding + delivery reconciliation from the event log: a
    # restarted receiver must not grant fresh retry budgets to in-flight
    # batches nor forget custodial state, and batches present in ground/
    # without an ingested record witness a crash between delivery and
    # logging (they remain on the link in the mask replay).
    rx_log_path = joinpath(run_dir, "events_rx.csv")
    if isfile(rx_log_path)
        rx_hist = CSV.read(rx_log_path, DataFrame)
        if !isempty(rx_hist)
            total_retries = count(==("retry"), rx_hist.Event)
            pending = Set(filter(f -> isdir(joinpath(link_path, f)), readdir(link_path)))
            for r in eachrow(rx_hist)
                r.Event == "retry" &&
                    r.Batch in pending &&
                    (retry_counts[r.Batch] = get(retry_counts, r.Batch, 0) + 1)
            end
            ingested_t = Dict(
                String(r.Batch) => r.SimTime for
                r in eachrow(rx_hist) if r.Event == "ingested"
            )
            unrecorded = sort!(collect(setdiff(Set(ground_seed), keys(ingested_t))))
            if !isempty(unrecorded)
                # Reconciliation synthesis: a batch present in ground/ without
                # an ingested record witnesses a crash between the delivery
                # move and the log append. The actual delivery time is
                # unrecoverable, so the record is synthesized at the re-attach
                # instant — masks, custodian, and consumers then agree the
                # batch is delivered.
                reconcile_t = TelemetryCore.get_current_sim_time(clock)
                for b in unrecorded
                    TelemetryCore.log_rx_event(run_dir, reconcile_t, b, "ingested", 0)
                    ingested_t[b] = reconcile_t
                end
                @warn "[RECEIVER] Re-attach: synthesized ingested records at $reconcile_t for $(length(unrecorded)) batches present in ground/ without a delivery record (crash window between delivery and logging)." batches =
                    first(unrecorded, min(5, length(unrecorded)))
            end
            if retention.enabled
                # Tally only: the prune queue itself is materialized lazily on
                # watermark breach (see the custodian block below), so it stays
                # empty on missions whose watermark is never reached.
                ground_payload_bytes = sum(
                    entry -> entry[3],
                    delivered_payload_queue(run_dir, ground_path);
                    init = 0,
                )
            end
        end
    end

    @info "[RECEIVER] Ground-station loop started."

    # Wall-clock instant [s] at which the current download slot completes.
    # Service completions are paced against this running deadline, so the
    # loop's own overhead — directory scans, the metrics row, the file moves —
    # is absorbed into the slot instead of being added to every one of them.
    service_due = time()

    try
        while true
            if stop !== nothing && stop[]
                @info "[RECEIVER] Stop signal received. Shutting down."
                break
            end
            if isfile(halt_path)
                @info "[RECEIVER] HALT sentinel detected. Shutting down."
                break
            end
            if deadline !== nothing && now() >= deadline
                break
            end
            if heartbeat_path !== nothing &&
               (now() - last_heartbeat).value >= TelemetryCore.HEARTBEAT_INTERVAL_MS
                touch(heartbeat_path)
                last_heartbeat = now()
            end

            sim_t = TelemetryCore.get_current_sim_time(clock)
            nominal_factor = TelemetryCore.get_bandwidth_factor(link.visibility, sim_t)
            disruption_scale = ChannelEffects.disruption_factor(link.disruptions, sim_t)
            bw_factor = nominal_factor * disruption_scale
            hours_elapsed = (sim_t - clock.start_sim_time).value / TelemetryCore.MS_PER_HOUR
            bandwidth_pct = bw_factor * 100
            nominal_pct = nominal_factor * 100
            disruption_active = disruption_scale < 1.0

            onboard_count =
                length(filter(f -> isdir(joinpath(onboard_path, f)), readdir(onboard_path)))
            link_count =
                length(filter(f -> isdir(joinpath(link_path, f)), readdir(link_path)))
            ground_count = ground_live + ground_arch

            if onboard_count != last_onboard ||
               link_count != last_link ||
               ground_count != last_ground ||
               lost_count != last_lost ||
               abs(bandwidth_pct - last_bw) > TelemetryCore.METRICS_BANDWIDTH_HYSTERESIS_PCT
                metrics = TelemetryCore.MissionMetrics(
                    sim_t,
                    now(),
                    hours_elapsed,
                    bandwidth_pct,
                    onboard_count,
                    link_count,
                    ground_count,
                    ground_live,
                    ground_arch,
                    nominal_pct,
                    lost_count,
                    total_retries,
                    disruption_active,
                )
                TelemetryCore.save_metrics(run_dir, metrics)

                last_onboard = onboard_count
                last_link = link_count
                last_ground = ground_count
                last_lost = lost_count
                last_bw = bandwidth_pct
            end

            # Retention custodian: prune delivered payload CSVs oldest-first
            # once the prunable tally exceeds the watermark — but never within
            # the grace window, which is the availability guarantee consumers
            # rely on (docs/src/interfaces.md). Only seg_*.csv files are
            # deleted; metadata.json stays and a PRUNED marker plus a `pruned`
            # event record the action.
            if retention.enabled && ground_payload_bytes > retention.watermark_bytes
                # Materialized on breach and refreshed when exhausted
                # mid-breach; empty between breach episodes (bounded growth).
                isempty(prune_queue) &&
                    append!(prune_queue, delivered_payload_queue(run_dir, ground_path))
                while ground_payload_bytes > retention.watermark_bytes &&
                      !isempty(prune_queue) &&
                      (sim_t - prune_queue[1][1]) >= retention.grace
                    (ingest_t, pruned_name, payload_bytes) = popfirst!(prune_queue)
                    batch_dir = joinpath(ground_path, pruned_name)
                    try
                        for f in readdir(batch_dir)
                            startswith(f, "seg_") &&
                                rm(joinpath(batch_dir, f); force = true)
                        end
                        touch(joinpath(batch_dir, "PRUNED"))
                        TelemetryCore.log_rx_event(run_dir, sim_t, pruned_name, "pruned", 0)
                        @info "[RECEIVER] Retention: pruned payload of $pruned_name (ingested $ingest_t)"
                        # Decrement only on success: after a failed prune the
                        # files are still on disk and the tally must stay
                        # truthful (the batch is not re-queued; logged above).
                        ground_payload_bytes -= payload_bytes
                    catch e
                        @error "[RECEIVER] Retention pruning failed for $pruned_name — continuing." exception =
                            e
                    end
                end
            end

            if status_panel
                status_text = if disruption_active && nominal_factor > 0.0
                    ev_label =
                        ChannelEffects.active_disruption_label(link.disruptions, sim_t)
                    ev_name = isempty(ev_label) ? "DISRUPTION" : uppercase(ev_label)
                    disruption_scale == 0.0 ? "$ev_name (Link down)" :
                    "$ev_name RECOVERY (Link: $(round(bandwidth_pct, digits=1))%)"
                elseif bw_factor > 0.0
                    "ACTIVE (Link: $(round(bandwidth_pct, digits=1))%)"
                else
                    "DORMANT (Out of window)"
                end
                panel_text =
                    "\e[H\e[J" *
                    "="^55 *
                    "\n" *
                    lpad("DEEP-SPACE TELEMETRY DASHBOARD", 42) *
                    "\n" *
                    "="^55 *
                    "\n" *
                    rpad("Mission Day:", 20) *
                    "$(round(hours_elapsed / 24.0, digits=2))\n" *
                    rpad("Current Status:", 20) *
                    "$status_text\n" *
                    rpad("Ground total:", 20) *
                    "$ground_count received data batches\n" *
                    rpad("Lost Batches:", 20) *
                    "$lost_count ($total_retries failed transfers)\n" *
                    "="^55 *
                    "\n"
                print(orig_stdout, panel_text)
                flush(orig_stdout)
            end

            pending_batches = filter(
                f -> TelemetryCore.is_batch_name(f) && isdir(joinpath(link_path, f)),
                readdir(link_path),
            )

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

                effective_slot_sec = max(
                    TelemetryCore.RECEIVER_SLEEP_FLOOR_SEC,
                    batch_transfer_sec / (bw_factor * clock.speed_up),
                )
                # The slot starts when the previous one completed; only after
                # an idle stretch of at least one slot does it start now. A
                # deadline that is still in the past after chaining means the
                # host cannot keep the modelled rate, and the loop yields.
                now_wall = time()
                service_due =
                    (
                        now_wall - service_due >= effective_slot_sec ? now_wall :
                        service_due
                    ) + effective_slot_sec
                wait_sec = service_due - time()
                wait_sec > 0.0 ? sleep(wait_sec) : yield()

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
                    @info "[RECEIVER] Bandwidth: $(round(bandwidth_pct))% | Batches buffered: $onboard_count | Total Data Batches: $ground_count"

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
                    if retention.enabled
                        batch_dir = joinpath(ground_path, batch_name)
                        payload = sum(
                            f ->
                                startswith(f, "seg_") ?
                                Int(filesize(joinpath(batch_dir, f))) : 0,
                            readdir(batch_dir);
                            init = 0,
                        )
                        # Tally only — the prune queue is materialized lazily
                        # on watermark breach (custodian block).
                        ground_payload_bytes += payload
                    end
                end
            elseif !isempty(pending_batches) && bw_factor > min_link_factor
                # Every in-flight batch awaits its round trip: sleep until the
                # earliest becomes eligible, capped at the poll interval.
                earliest = minimum(get(retry_after, f, sim_t) for f in pending_batches)
                wait_sec =
                    (TelemetryCore.due_wall_time(clock, earliest) - now()).value / 1000.0
                sleep(
                    clamp(
                        wait_sec,
                        TelemetryCore.RECEIVER_SLEEP_FLOOR_SEC,
                        TelemetryCore.RECEIVER_POLL_INTERVAL_SEC,
                    ),
                )
            else
                watch_folder(link_path, TelemetryCore.RECEIVER_POLL_INTERVAL_SEC)
            end
        end
    finally
        # Heartbeat exists only while the loop runs: removing it tells the
        # watchdog this component finished rather than stalled.
        heartbeat_path !== nothing && rm(heartbeat_path; force = true)
        status_panel && println(orig_stdout, "\n")
    end
end

end # module Receiver
