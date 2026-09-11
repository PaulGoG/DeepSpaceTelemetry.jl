"""
    Emitter

The satellite-side loop: strain generation and batching, onboard queue
management (live FIFO with absolute priority, archive LIFO backfill),
link-gated transmission under the in-flight cap, and ground-truth `gen`/`tx`
event logging. Re-entrant: a restarted emitter reconstructs its queues and
counter from the run directory and event log.
"""
module Emitter

using ..TelemetryCore
using ..ChannelEffects
using ..VirtualInstrument
using Dates: Dates, DateTime, Millisecond, Second, now
using ProgressMeter: ProgressMeter, @showprogress
using Random: Random, Xoshiro

"""
    pre_populate(start_sim_time, run_id; kwargs...) -> (instrument, pending_segments)

Simulates satellite downtime prior to the start of the active mission window.
Fills the onboard SSD buffer with archived data batches to create a starting backlog.

Returns the `InstrumentState` used for generation together with any trailing
segments that did not fill a complete batch. Both must be handed to
[`run_emitter`](@ref) so that the data stream (in particular an external CSV
consumed via `ext_index`) continues without restarting at the first sample.

# Keyword arguments

  - `sample_rate`: instrument sample rate [Hz].
  - `segment_duration_sec`: content span of one segment [mission s].
  - `batch_size`: segments per batch.
  - `initial_downtime_days`: span of the blind spot before `start_sim_time`
    [days]; `≤ 0` skips the pre-population and returns an instrument
    anchored at `start_sim_time`.
  - `data_source`: `"synthetic"` or `"external"`.
  - `ext_path`: path of the external CSV series (`data_source = "external"`).
  - `rng`: the instrument's RNG, seeded from `simulation.rng_seed`.
  - `markers`: event markers, stamped into the batch holding their instant.
  - `generation_gaps`: scheduled `(start, stop)` intervals without data
    production ([`skip_generation_gaps!`](@ref)).
  - `onboard_capacity_batches`: recorder ceiling; data beyond it is discarded.
  - `confusion_observation_years`, `noise_f_min_hz`: galactic-confusion fit
    and lower band edge of the synthetic noise model
    ([`VirtualInstrument.lisa_noise_psd`](@ref)).
"""
function pre_populate(
    start_sim_time::DateTime,
    run_id::String;
    sample_rate::Float64 = 1024.0,
    segment_duration_sec::Float64 = 60.0,
    batch_size::Int = 15,
    initial_downtime_days::Float64 = 3.0,
    data_source::String = "synthetic",
    ext_path::String = "",
    rng::Random.AbstractRNG = Xoshiro(0),
    markers::Vector{TelemetryCore.EventMarker} = TelemetryCore.EventMarker[],
    generation_gaps::Vector{Tuple{DateTime,DateTime}} = Tuple{DateTime,DateTime}[],
    onboard_capacity_batches::Int = typemax(Int),
    confusion_observation_years::Float64 = 1.0,
    noise_f_min_hz::Float64 = 1e-5,
)
    downtime_ms = max(0, round(Int, initial_downtime_days * TelemetryCore.MS_PER_DAY))
    downtime_start = start_sim_time - Millisecond(downtime_ms)

    vi = VirtualInstrument.InstrumentState(
        downtime_start,
        sample_rate,
        segment_duration_sec,
        data_source,
        ext_path;
        rng = rng,
        confusion_observation_years = confusion_observation_years,
        noise_f_min_hz = noise_f_min_hz,
    )
    pending = TelemetryCore.DataSegment[]

    if initial_downtime_days <= 0.0
        return vi, pending
    end

    run_dir = TelemetryCore.run_directory(run_id)
    buffer_path = joinpath(run_dir, "onboard")

    batch_counter = 1

    @info "[EMITTER] Pre-populating onboard buffer for $(initial_downtime_days) days of downtime..."

    total_segs =
        ceil(Int, (start_sim_time - downtime_start).value / 1000 / segment_duration_sec)

    recorder_full = false
    @showprogress "Pre-populating onboard buffer..." for _ in 1:total_segs
        if vi.last_t >= start_sim_time
            break
        end
        skip_generation_gaps!(vi, pending, generation_gaps, run_dir) && continue
        seg = VirtualInstrument.next_segment!(vi)
        push!(pending, seg)

        if length(pending) >= batch_size && batch_counter - 1 >= onboard_capacity_batches
            # Recorder ceiling: nothing leaves the buffer before the mission
            # starts, so the overflow gap stays open into run_emitter.
            recorder_full || TelemetryCore.log_tx_event(
                run_dir,
                pending[1].timestamp,
                "RECORDER",
                "gap_start",
            )
            recorder_full ||
                @warn "[EMITTER] On-board recorder full ($(batch_counter - 1) batches): blind-spot data beyond the ceiling is discarded."
            recorder_full = true
            empty!(pending)
        elseif length(pending) >= batch_size
            # created_at is the finalization instant on the mission timeline
            # (the instrument has observed the whole payload; inside the blind
            # spot, i.e. before mission start), never wall-clock time. The
            # content epoch (first-sample timestamp) is persisted alongside by
            # save_batch — the same contract as the mission-phase path.
            finalized_at = vi.last_t
            batch = TelemetryCore.DataBatch(batch_counter, copy(pending), finalized_at)
            batch_name = TelemetryCore.batch_name(batch_counter, false)
            batch_dir = joinpath(buffer_path, batch_name)

            stamp_markers!(batch_dir, batch, batch_name, run_dir, markers, vi.last_t)
            # Ground-truth milestone: generation = finalization time.
            TelemetryCore.log_tx_event(run_dir, finalized_at, batch_name, "gen")
            empty!(pending)
            batch_counter += 1
        end
    end

    @info "[EMITTER] Pre-population complete. Buffered $(batch_counter-1) ARCH_ data batches."
    return vi, pending
end

"""
    skip_generation_gaps!(vi, pending, gaps, run_dir) -> Bool

Scheduled generation gap: when the instrument's next content instant lies
inside one of `gaps` (`(start, stop)` intervals), the segments of the
incomplete batch are discarded (as in an emitter outage, so batch geometry
stays uniform), the gap is bounded in `events_tx.csv` — `gap_start` at the
first discarded epoch (or the content end when nothing was pending),
`gap_end` at the gap's end, Batch = `SCHEDULED` — and the instrument's
content time jumps to the gap end. Gap boundaries snap to segment
boundaries. Returns `true` when a gap was skipped.
"""
function skip_generation_gaps!(
    vi::VirtualInstrument.InstrumentState,
    pending::Vector{TelemetryCore.DataSegment},
    gaps::Vector{Tuple{DateTime,DateTime}},
    run_dir::String,
)
    for (g0, g1) in gaps
        g0 <= vi.last_t < g1 || continue
        gap_start = isempty(pending) ? vi.last_t : pending[1].timestamp
        TelemetryCore.log_tx_event(run_dir, gap_start, "SCHEDULED", "gap_start")
        TelemetryCore.log_tx_event(run_dir, g1, "SCHEDULED", "gap_end")
        @info "[EMITTER] Scheduled generation gap: no data from $gap_start until $g1."
        empty!(pending)
        vi.last_t = g1
        return true
    end
    return false
end

"""
    stamp_markers!(batch_dir, batch, batch_name, run_dir, markers, content_end)

Saves `batch` ([`TelemetryCore.save_batch`](@ref)) with the labels of the
event markers whose instant lies in its content span, and appends one
`marker` row per hit to `events_tx.csv` (`SimTime` = the marker instant,
`Batch` = the containing batch) so live consumers learn which batch holds
the event the moment it becomes transmittable.
"""
function stamp_markers!(
    batch_dir::String,
    batch::TelemetryCore.DataBatch,
    batch_name::String,
    run_dir::String,
    markers::Vector{TelemetryCore.EventMarker},
    content_end::DateTime,
)
    hits = TelemetryCore.batch_markers(markers, batch.segments[1].timestamp, content_end)
    TelemetryCore.save_batch(batch_dir, batch; markers = [m.label for m in hits])
    for m in hits
        TelemetryCore.log_tx_event(run_dir, m.time, batch_name, "marker")
    end
    return nothing
end

# --- Emitter Main Loop ---
"""
    run_emitter(clock, link, run_id; kwargs...)

The main satellite payload loop. Continuously generates scientific data (or reads from external CSV),
packages it into batches, and manages the DSN transmission queue using strict priority logic
(Live FIFO > Archive LIFO).

`link` is the composite [`ChannelEffects.LinkModel`](@ref) (visibility ×
disruption timeline): batches are stamped `LIVE_` and transmitted only while
the link is transmittable — during a disruption blackout the satellite keeps
generating `ARCH_` batches that accumulate onboard.

Pass the `instrument` and `pending_segments` returned by [`pre_populate`](@ref)
to continue the pre-populated data stream without gaps or duplication; when
`instrument === nothing` a fresh `InstrumentState` starting at the current
mission time is created instead (seeded by `rng`).

Generation is paced by the mission clock, not by the loop's own start: a
segment is produced once the mission clock has passed the end of its content
interval (`vi.last_t + segment_duration_sec`), and the loop sleeps until the exact wall
instant of the next due segment ([`TelemetryCore.due_wall_time`](@ref)).
A late start or a stall is recovered by generating back-to-back (yielding to
the partner task on every catch-up iteration) until the content has caught
up with the clock, so the content epoch of the stream tracks mission time
within one segment period. Each sleep is capped at
[`TelemetryCore.EMITTER_MAX_SLEEP_SEC`](@ref) so the heartbeat and the
stop/deadline checks stay responsive at low `speed_up`. A content lag that
persists above one period for longer than
[`TelemetryCore.EMITTER_LAG_WARN_SEC`](@ref) is reported once as a warning
(the host cannot keep pace); the maximum lag is logged at loop exit.

# Keyword arguments

  - `sample_rate`: instrument sample rate [Hz].
  - `segment_duration_sec`: content span of one segment [mission s].
  - `batch_size`: segments per batch.
  - `data_source`: `"synthetic"` or `"external"`.
  - `ext_path`: path of the external CSV series (`data_source = "external"`).
  - `instrument`: the `InstrumentState` returned by [`pre_populate`](@ref),
    or `nothing` for a fresh instrument anchored at the current mission time.
  - `pending_segments`: the partial batch returned by [`pre_populate`](@ref).
  - `rng`: RNG of a freshly created instrument (ignored when `instrument`
    is given).
  - `deadline`: absolute wall-clock stop shared by both components.
  - `stop`: cooperative stop flag raised by the supervisor.
  - `heartbeat_path`: liveness file touched every
    [`TelemetryCore.HEARTBEAT_INTERVAL_MS`](@ref) when set; removed on exit.
  - `max_inflight_batches`: cap on batches simultaneously on the link.
  - `markers`: event markers, stamped into the batch holding their instant.
  - `generation_gaps`: scheduled `(start, stop)` intervals without data
    production ([`skip_generation_gaps!`](@ref)).
  - `onboard_capacity_batches`: recorder ceiling; new data is discarded
    while the buffer holds that many batches.
  - `confusion_observation_years`, `noise_f_min_hz`: galactic-confusion fit
    and lower band edge of the synthetic noise model of a freshly created
    instrument ([`VirtualInstrument.lisa_noise_psd`](@ref)).
"""
function run_emitter(
    clock::TelemetryCore.SimulationClock,
    link::ChannelEffects.LinkModel,
    run_id::String;
    sample_rate::Float64 = 1024.0,
    segment_duration_sec::Float64 = 60.0,
    batch_size::Int = 15,
    data_source::String = "synthetic",
    ext_path::String = "",
    instrument::Union{VirtualInstrument.InstrumentState,Nothing} = nothing,
    pending_segments::Vector{TelemetryCore.DataSegment} = TelemetryCore.DataSegment[],
    rng::Random.AbstractRNG = Xoshiro(0),
    deadline::Union{DateTime,Nothing} = nothing,
    stop::Union{Threads.Atomic{Bool},Nothing} = nothing,
    heartbeat_path::Union{String,Nothing} = nothing,
    max_inflight_batches::Int = 5,
    markers::Vector{TelemetryCore.EventMarker} = TelemetryCore.EventMarker[],
    generation_gaps::Vector{Tuple{DateTime,DateTime}} = Tuple{DateTime,DateTime}[],
    onboard_capacity_batches::Int = typemax(Int),
    confusion_observation_years::Float64 = 1.0,
    noise_f_min_hz::Float64 = 1e-5,
)
    # A fresh instrument anchors at the *current* mission time, not the
    # mission epoch: on a mid-mission restart the outage becomes a genuine
    # generation gap instead of a replayed stream.
    vi =
        instrument === nothing ?
        VirtualInstrument.InstrumentState(
            TelemetryCore.get_current_sim_time(clock),
            sample_rate,
            segment_duration_sec,
            data_source,
            ext_path;
            rng = rng,
            confusion_observation_years = confusion_observation_years,
            noise_f_min_hz = noise_f_min_hz,
        ) : instrument
    run_dir = TelemetryCore.run_directory(run_id)
    buffer_path = joinpath(run_dir, "onboard")
    link_path = joinpath(run_dir, "link")
    foreach(mkpath, (buffer_path, link_path)) # idempotent: standalone/restart entry

    # Internal state tracking to avoid expensive `readdir` polling
    onboard_live_queue = String[]
    onboard_arch_queue = String[]

    # Re-entrant census: rebuild BOTH queues (a restarted emitter must not
    # orphan LIVE batches stranded onboard at the crash) and resume the
    # batch counter from the ground-truth event log — directory counts alone
    # would collide with batches already delivered downstream. Stray
    # directories that merely share the prefix parse to ID 0.
    all_onboard = filter(f -> isdir(joinpath(buffer_path, f)), readdir(buffer_path))
    archived = filter(TelemetryCore.is_archive_batch, all_onboard)
    sort!(archived, by = TelemetryCore.batch_id, rev = true) # LIFO internal
    append!(onboard_arch_queue, archived)
    stranded_live = filter(TelemetryCore.is_live_batch, all_onboard)
    sort!(stranded_live, by = TelemetryCore.batch_id) # FIFO
    append!(onboard_live_queue, stranded_live)
    isempty(stranded_live) ||
        @info "[EMITTER] Re-attach: recovered $(length(stranded_live)) stranded LIVE batches."
    batch_counter =
        1 + max(
            isempty(all_onboard) ? 0 : maximum(TelemetryCore.batch_id, all_onboard),
            TelemetryCore.max_logged_batch_id(run_dir),
        )
    pending = copy(pending_segments)
    halt_path = joinpath(run_dir, "HALT")
    last_heartbeat = now() - Second(2)
    # Recorder-overflow gap left open by the pre-population or a previous
    # emitter: closed at the first finalization that finds room.
    recorder_full = TelemetryCore.open_recorder_gap(run_dir)

    @info "[EMITTER] Logic: near-real-time (NRT) FIFO priority + archive backfill (LIFO). Run: $run_id"

    seg_period = Second(round(Int, vi.segment_duration_sec))
    # Content-lag telemetry: lag = mission time at finalization − content end
    # of the finalized batch. A persistent lag means the host cannot keep
    # pace; a transient one (startup compilation, GC, a partner stall on a
    # single thread) is recovered by the catch-up burst below.
    max_lag = Millisecond(0)
    lag_since = DateTime(0) # sentinel: not currently lagging
    lag_warned = false

    try
        while true
            if stop !== nothing && stop[]
                @info "[EMITTER] Stop signal received. Shutting down."
                break
            end
            if isfile(halt_path)
                @info "[EMITTER] HALT sentinel detected. Shutting down."
                break
            end
            if deadline !== nothing && now() >= deadline
                @info "[EMITTER] Mission deadline reached. Shutting down."
                break
            end
            if heartbeat_path !== nothing &&
               (now() - last_heartbeat).value >= TelemetryCore.HEARTBEAT_INTERVAL_MS
                touch(heartbeat_path)
                last_heartbeat = now()
            end

            # 1. Pacing on the mission clock: the next segment is due once its
            #    content interval has elapsed (causality — the instrument
            #    delivers a segment after observing it). Sleep until the exact
            #    due wall instant, capped so the checks above stay responsive;
            #    on the catch-up path yield so a partner task on the same
            #    thread is never starved.
            skip_generation_gaps!(vi, pending, generation_gaps, run_dir) && continue
            sim_t = TelemetryCore.get_current_sim_time(clock)
            content_end = vi.last_t + seg_period
            if content_end > sim_t
                due = TelemetryCore.due_wall_time(clock, content_end)
                deadline !== nothing && (due = min(due, deadline))
                wait_sec = (due - now()).value / 1000.0
                sleep(clamp(wait_sec, 0.0, TelemetryCore.EMITTER_MAX_SLEEP_SEC))
                continue
            end
            yield()

            # 2. Generation
            seg = VirtualInstrument.next_segment!(vi)
            push!(pending, seg)

            # 3. Batch Finalization — or discard at the recorder ceiling
            #    (no eviction: the buffer keeps what it holds, new data is
            #    lost until a batch leaves for the link).
            if length(pending) >= batch_size &&
               length(onboard_live_queue) + length(onboard_arch_queue) >=
               onboard_capacity_batches
                recorder_full || TelemetryCore.log_tx_event(
                    run_dir,
                    pending[1].timestamp,
                    "RECORDER",
                    "gap_start",
                )
                recorder_full ||
                    @warn "[EMITTER] On-board recorder full ($onboard_capacity_batches batches): new data is discarded until the buffer drains."
                recorder_full = true
                empty!(pending)
            elseif length(pending) >= batch_size
                if recorder_full
                    TelemetryCore.log_tx_event(
                        run_dir,
                        pending[1].timestamp,
                        "RECORDER",
                        "gap_end",
                    )
                    @info "[EMITTER] On-board recorder has room again: recording resumes at $(pending[1].timestamp)."
                    recorder_full = false
                end
                # Classification ruling: LIVE/ARCH follows the
                # link state at finalization time — flight software marks data
                # near-real-time only if the link is up when it is ready to send.
                # The payload's content epoch is persisted independently
                # (metadata.json `content_epoch`, masks/batch_epochs.csv), so
                # pacing lag can shift classification but never science
                # provenance.
                is_live = ChannelEffects.is_transmittable(link, sim_t)
                # created_at = finalization instant on the mission timeline.
                batch = TelemetryCore.DataBatch(batch_counter, copy(pending), sim_t)
                batch_name = TelemetryCore.batch_name(batch_counter, is_live)
                batch_dir = joinpath(buffer_path, batch_name)

                stamp_markers!(batch_dir, batch, batch_name, run_dir, markers, vi.last_t)

                # Add to internal queue
                if is_live
                    # LIVE queue is FIFO: append at the tail, drain from the head.
                    push!(onboard_live_queue, batch_name)
                else
                    # ARCH queue is LIFO: insert at the head so popfirst! yields newest-first.
                    pushfirst!(onboard_arch_queue, batch_name)
                end

                @info "[EMITTER] Gen  | $batch_name @ SimTime: $(batch.segments[1].timestamp)"
                TelemetryCore.log_tx_event(run_dir, sim_t, batch_name, "gen")
                empty!(pending)
                batch_counter += 1

                lag = sim_t - vi.last_t
                lag > max_lag && (max_lag = lag)
                if lag > seg_period
                    lag_since == DateTime(0) && (lag_since = now())
                    if !lag_warned &&
                       (now() - lag_since).value / 1000.0 >
                       TelemetryCore.EMITTER_LAG_WARN_SEC
                        lag_warned = true
                        @warn "[EMITTER] Generation runs $(round(lag.value / 1000, digits = 1)) mission-s " *
                              "($(round(lag.value / 1000 / clock.speed_up, digits = 2)) wall-s) behind the " *
                              "mission clock for more than $(TelemetryCore.EMITTER_LAG_WARN_SEC) s: " *
                              "the host cannot keep pace (per-segment cost exceeds " *
                              "segment_duration_sec / speed_up). Increase segment_duration_sec or " *
                              "decrease speed_up."
                    end
                else
                    lag_since = DateTime(0)
                end
            end

            # 4. Transmission — gated on the effective link (visibility AND no blackout)
            if ChannelEffects.is_transmittable(link, sim_t)
                # In-flight occupancy is the link/ directory listing: a slot
                # frees the moment the receiver moves a batch out.
                link_count =
                    length(filter(f -> isdir(joinpath(link_path, f)), readdir(link_path)))

                # Refill every free in-flight slot: transmission opportunities
                # are bounded by the cap and the receiver's service rate, not
                # by the generation cadence (one segment period per iteration).
                while link_count < max_inflight_batches
                    next_batch = ""
                    reason = ""
                    if !isempty(onboard_live_queue)
                        next_batch = popfirst!(onboard_live_queue) # FIFO for Live
                        reason = "Priority"
                    elseif !isempty(onboard_arch_queue)
                        next_batch = popfirst!(onboard_arch_queue) # LIFO for Arch (since we pushfirst!)
                        reason = "Backfill"
                    end
                    isempty(next_batch) && break
                    TelemetryCore.backup_existing_dir(joinpath(link_path, next_batch))
                    mv(joinpath(buffer_path, next_batch), joinpath(link_path, next_batch))
                    @info "[EMITTER] Tx ->| $next_batch ($reason)"
                    TelemetryCore.log_tx_event(run_dir, sim_t, next_batch, "tx")
                    link_count += 1
                end
            end
        end
        @info "[EMITTER] Pacing summary: maximum content lag $(round(max_lag.value / 1000, digits = 1)) mission-s " *
              "($(round(max_lag.value / 1000 / clock.speed_up, digits = 3)) wall-s); content end $(vi.last_t)."
    finally
        # Heartbeat exists only while the loop runs — removed on every exit
        # path (including a throw), so the watchdog reads "finished", never a
        # stale "stalled".
        heartbeat_path !== nothing && rm(heartbeat_path; force = true)
    end
end

end # module Emitter
