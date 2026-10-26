"""
    Emitter

The satellite-side loop: payload generation and batching, onboard queue
management (live FIFO with absolute priority, archive LIFO backfill),
link-gated transmission under the in-flight cap, and ground-truth `gen`/`tx`
event logging. Re-entrant: a restarted emitter reconstructs its queues and
counter from the run directory and event log.
"""
module Emitter

using ..TelemetryCore: TelemetryCore
using ..ChannelEffects
using ..VirtualInstrument
using Dates: Dates, DateTime, Millisecond
using ProgressMeter: ProgressMeter, @showprogress

"""
    instrument_epoch(start_sim_time::DateTime, initial_downtime_days::Real) -> DateTime

Anchor of the instrument that pre-populates the onboard buffer: the mission
epoch `start_sim_time` less the initial downtime, clamped at the epoch for a
non-positive downtime.
"""
function instrument_epoch(start_sim_time::DateTime, initial_downtime_days::Real)
    downtime_ms = max(0, round(Int, initial_downtime_days * TelemetryCore.MS_PER_DAY))
    return start_sim_time - Millisecond(downtime_ms)
end

"""
    pre_populate(instrument, start_sim_time, run_id; batch_size, kwargs...) -> (instrument, pending_segments)

Fills the on-board recorder (`onboard/`) with the `ARCH_` batches produced
during the initial downtime, the backlog the active mission window starts
with.

`instrument` is the [`VirtualInstrument.InstrumentState`](@ref) anchored at
the start of the blind spot ([`instrument_epoch`](@ref)); the pre-population
runs from that anchor to `start_sim_time`, and an instrument anchored at or
after `start_sim_time` returns at once with no batch written.

Returns the instrument together with any trailing segments that did not fill
a complete batch. Both must be handed to [`run_emitter`](@ref), which
completes the partial batch in the mission phase.

# Keyword arguments

  - `batch_size`: segments per batch (required).
  - `markers`: event markers, stamped into the batch holding their instant.
  - `generation_gaps`: scheduled `(start, stop)` intervals without data
    production ([`skip_generation_gaps!`](@ref)).
  - `onboard_capacity_batches`: recorder ceiling; data beyond it is discarded.
  - `hole_feed`: the declared-hole feed the emitter appends its scheduled
    and recorder gaps to, `nothing` for none. A scheduled gap inside the
    blind spot is declared at `start_sim_time`; a recorder gap opened here
    is declared by [`run_emitter`](@ref) when it closes.
"""
function pre_populate(
    instrument::VirtualInstrument.InstrumentState,
    start_sim_time::DateTime,
    run_id::String;
    batch_size::Int,
    markers::Vector{TelemetryCore.EventMarker} = TelemetryCore.EventMarker[],
    generation_gaps::Vector{Tuple{DateTime,DateTime}} = Tuple{DateTime,DateTime}[],
    onboard_capacity_batches::Int = typemax(Int),
    hole_feed::Union{TelemetryCore.HoleFeed,Nothing} = nothing,
)
    vi = instrument
    downtime_start = vi.last_t
    pending = TelemetryCore.DataSegment[]
    downtime_start < start_sim_time || return vi, pending
    downtime_days = (start_sim_time - downtime_start).value / TelemetryCore.MS_PER_DAY

    run_dir = TelemetryCore.run_directory(run_id)
    buffer_path = joinpath(run_dir, "onboard")

    batch_counter = 1

    @info "[EMITTER] Pre-populating onboard buffer for $(round(downtime_days, digits = 3)) days of downtime..."

    total_segs =
        ceil(Int, (start_sim_time - downtime_start).value / 1000 / vi.segment_duration_sec)

    recorder_full = false
    # Carriage-return frames would fill the log of a detached run.
    @showprogress desc = "Pre-populating onboard buffer..." enabled = (stderr isa Base.TTY) for _ in
                                                                                                1:total_segs

        if vi.last_t >= start_sim_time
            break
        end
        skip_generation_gaps!(
            vi,
            pending,
            generation_gaps,
            run_dir;
            hole_feed = hole_feed,
            declared_at = start_sim_time,
        ) && continue
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
            # (the content end, inside the blind spot), not wall-clock time;
            # save_batch persists the content epoch beside it, as on the
            # mission-phase path.
            finalized_at = vi.last_t
            batch = TelemetryCore.DataBatch(batch_counter, copy(pending), finalized_at)
            batch_name = TelemetryCore.batch_name(batch_counter, false)
            batch_dir = joinpath(buffer_path, batch_name)

            stamp_markers!(
                batch_dir,
                batch,
                batch_name,
                run_dir,
                markers,
                vi.last_t;
                payload_row = VirtualInstrument.payload_row(vi, batch.segments[1].id),
            )
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
    skip_generation_gaps!(vi, pending, gaps, run_dir; hole_feed = nothing, declared_at = nothing) -> Bool

Scheduled generation gap: when the instrument's next content instant lies
inside one of `gaps` (`(start, stop)` intervals), the segments of the
incomplete batch are discarded (as in an emitter outage, so batch geometry
stays uniform) and the content clock resumes at the first segment boundary
at or after the gap's end ([`VirtualInstrument.advance_to!`](@ref)): the
sampling phase of the payload origin is kept, so segment identifiers and
payload rows continue on the same grid. The gap is bounded in
`events_tx.csv` (Batch = `SCHEDULED`) by `gap_start` at the first discarded
epoch (or the content end when nothing was pending) and `gap_end` at the
resumption instant, so `[gap_start, gap_end)` is exactly the content not
recorded. With a `hole_feed`, the same interval is appended to the
declared-hole feed as a `scheduled` hole declared at `declared_at` (the
resumption instant when `nothing`). Returns `true` when a gap was skipped.
"""
function skip_generation_gaps!(
    vi::VirtualInstrument.InstrumentState,
    pending::Vector{TelemetryCore.DataSegment},
    gaps::Vector{Tuple{DateTime,DateTime}},
    run_dir::String;
    hole_feed::Union{TelemetryCore.HoleFeed,Nothing} = nothing,
    declared_at::Union{DateTime,Nothing} = nothing,
)
    for (g0, g1) in gaps
        g0 <= vi.last_t < g1 || continue
        gap_start = isempty(pending) ? vi.last_t : pending[1].timestamp
        resume = VirtualInstrument.advance_to!(vi, g1)
        TelemetryCore.log_tx_event(run_dir, gap_start, "SCHEDULED", "gap_start")
        TelemetryCore.log_tx_event(run_dir, resume, "SCHEDULED", "gap_end")
        hole_feed === nothing || TelemetryCore.declare_gap_hole!(
            hole_feed,
            something(declared_at, resume),
            "scheduled",
            gap_start,
            resume,
        )
        @info "[EMITTER] Scheduled generation gap: no data from $gap_start until $resume."
        empty!(pending)
        return true
    end
    return false
end

"""
    stamp_markers!(batch_dir, batch, batch_name, run_dir, markers, content_end; payload_row)

Saves `batch` ([`TelemetryCore.save_batch`](@ref)) with its `payload_row`
and the labels of the event markers whose instant lies in its content span,
and appends one `marker` row per hit to `events_tx.csv` (`SimTime` = the
marker instant, `Batch` = the containing batch) so live consumers learn
which batch holds the event the moment it becomes transmittable.
"""
function stamp_markers!(
    batch_dir::String,
    batch::TelemetryCore.DataBatch,
    batch_name::String,
    run_dir::String,
    markers::Vector{TelemetryCore.EventMarker},
    content_end::DateTime;
    payload_row::Int,
)
    hits = TelemetryCore.batch_markers(markers, batch.segments[1].timestamp, content_end)
    TelemetryCore.save_batch(
        batch_dir,
        batch;
        markers = [m.label for m in hits],
        payload_row = payload_row,
    )
    for m in hits
        TelemetryCore.log_tx_event(run_dir, m.time, batch_name, "marker")
    end
    return nothing
end

"""
    transmit_onboard!(live_queue, arch_queue, link, sim_t, run_dir; max_inflight_batches) -> Int

Places on-board batches on the downlink while `link` is transmittable at
`sim_t` (visibility and no blackout). Free in-flight slots, the `link/`
listing below `max_inflight_batches` (a slot frees the moment the receiver
moves a batch out), are refilled from `live_queue` (FIFO, absolute
priority), then from `arch_queue` (held newest first, so the archive drains
LIFO). Each move from `onboard/` to `link/` is appended to `events_tx.csv`
as a `tx` row. Returns the number of batches placed.
"""
function transmit_onboard!(
    live_queue::Vector{String},
    arch_queue::Vector{String},
    link::ChannelEffects.LinkModel,
    sim_t::DateTime,
    run_dir::String;
    max_inflight_batches::Int,
)
    ChannelEffects.is_transmittable(link, sim_t) || return 0
    buffer_path = joinpath(run_dir, "onboard")
    link_path = joinpath(run_dir, "link")
    link_count = length(filter(f -> isdir(joinpath(link_path, f)), readdir(link_path)))
    placed = 0
    while link_count < max_inflight_batches
        next_batch, reason = if !isempty(live_queue)
            popfirst!(live_queue), "Priority"
        elseif !isempty(arch_queue)
            popfirst!(arch_queue), "Backfill"
        else
            break
        end
        TelemetryCore.backup_existing_dir(joinpath(link_path, next_batch))
        mv(joinpath(buffer_path, next_batch), joinpath(link_path, next_batch))
        @info "[EMITTER] Tx ->| $next_batch ($reason)"
        TelemetryCore.log_tx_event(run_dir, sim_t, next_batch, "tx")
        link_count += 1
        placed += 1
    end
    return placed
end

# --- Emitter Main Loop ---
"""
    run_emitter(clock, link, run_id, instrument; batch_size, kwargs...)

The spacecraft loop: segments from `instrument` (synthetic, or read from an
external CSV) are batched and placed on the downlink, live FIFO with
absolute priority over the archive LIFO ([`transmit_onboard!`](@ref)).
`link` is the composite [`ChannelEffects.LinkModel`](@ref) (visibility ×
disruption timeline): a batch finalized while the link is transmittable is
stamped `LIVE_`, any other `ARCH_`, so the batches generated during a
disruption blackout accumulate onboard.

`instrument` is the [`VirtualInstrument.InstrumentState`](@ref) the stream
continues from: on the first start the one returned by
[`pre_populate`](@ref); on a restart the instrument
[`VirtualInstrument.resumed`](@ref) at the first segment boundary at or
after the current mission time, with the payload origin of the first start,
which leaves a genuine generation gap.

`clock` is the [`TelemetryCore.TickClock`](@ref) of the mission, paced or
not: in wall mode the driver ([`TelemetryCore.run_ticks!`](@ref)) holds each
wakeup back to its wall instant, which changes when the loop runs but not
what it produces. Generation is paced by the mission clock, not by the
loop's own start: a segment is produced once the clock has passed the end
of its content interval (`vi.last_t + segment_duration_sec`). While no
segment is due the loop serves the downlink and parks the task
([`TelemetryCore.wait_until!`](@ref)) until that instant or the next
boundary of the payload grid, whichever comes first, so a scheduled
generation gap interrupts production but not transmission. The loop ends at
the horizon ([`TelemetryCore.horizon_reached`](@ref)), on the stop flag, or
on the `HALT` sentinel.

# Keyword arguments

  - `batch_size`: segments per batch (required).
  - `pending_segments`: the partial batch returned by [`pre_populate`](@ref).
  - `stop`: cooperative stop flag raised by the supervisor.
  - `max_inflight_batches`: cap on batches simultaneously on the link.
  - `markers`: event markers, stamped into the batch holding their instant.
    The synthetic payload flags them through the instrument
    ([`VirtualInstrument.FlaggedSignal`](@ref)), not through this argument.
  - `generation_gaps`: scheduled `(start, stop)` intervals without data
    production ([`skip_generation_gaps!`](@ref)).
  - `onboard_capacity_batches`: recorder ceiling; new data is discarded
    while the buffer holds that many batches.
  - `hole_feed`: the declared-hole feed for the scheduled and recorder gaps,
    `nothing` for none. A scheduled gap is declared at the mission instant
    it is skipped at, a recorder gap at the finalization that closes it.
"""
function run_emitter(
    clock::TelemetryCore.TickClock,
    link::ChannelEffects.LinkModel,
    run_id::String,
    instrument::VirtualInstrument.InstrumentState;
    batch_size::Int,
    pending_segments::Vector{TelemetryCore.DataSegment} = TelemetryCore.DataSegment[],
    stop::Union{Threads.Atomic{Bool},Nothing} = nothing,
    max_inflight_batches::Int = 5,
    markers::Vector{TelemetryCore.EventMarker} = TelemetryCore.EventMarker[],
    generation_gaps::Vector{Tuple{DateTime,DateTime}} = Tuple{DateTime,DateTime}[],
    onboard_capacity_batches::Int = typemax(Int),
    hole_feed::Union{TelemetryCore.HoleFeed,Nothing} = nothing,
)
    vi = instrument
    run_dir = TelemetryCore.run_directory(run_id)
    buffer_path = joinpath(run_dir, "onboard")
    link_path = joinpath(run_dir, "link")
    foreach(mkpath, (buffer_path, link_path)) # idempotent: standalone/restart entry

    # Internal state tracking to avoid expensive `readdir` polling
    onboard_live_queue = String[]
    onboard_arch_queue = String[]

    # Re-entrant census: both queues are rebuilt, so a restart does not
    # orphan LIVE batches stranded onboard, and the batch counter resumes
    # from the event log, since onboard directory counts alone would reuse
    # the IDs of batches already delivered. Stray directories sharing the
    # prefix parse to ID 0.
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
    # Recorder-overflow gap left open by the pre-population or a previous
    # emitter: closed at the first finalization that finds room. Its start
    # is kept for the declared-hole feed.
    recorder_gap_start::Union{DateTime,Nothing} =
        TelemetryCore.open_recorder_gap_start(run_dir)
    recorder_full = recorder_gap_start !== nothing

    @info "[EMITTER] Logic: near-real-time (NRT) FIFO priority + archive backfill (LIFO). Run: $run_id"

    seg_period = TelemetryCore.segment_period(vi.segment_duration_sec)

    while true
        if stop !== nothing && stop[]
            @info "[EMITTER] Stop signal received. Shutting down."
            break
        end
        if isfile(halt_path)
            @info "[EMITTER] HALT sentinel detected. Shutting down."
            break
        end
        if TelemetryCore.horizon_reached(clock)
            @info "[EMITTER] Mission horizon reached. Shutting down."
            break
        end

        # 1. Pacing (see the docstring): a segment is due once its content
        #    interval has elapsed, since the instrument delivers what it
        #    has observed. Until then serve the downlink and sleep to the
        #    next grid boundary; on the catch-up path, yield so a partner
        #    task on the same thread is not starved.
        skip_generation_gaps!(
            vi,
            pending,
            generation_gaps,
            run_dir;
            hole_feed = hole_feed,
            declared_at = TelemetryCore.get_current_sim_time(clock),
        ) && continue
        sim_t = TelemetryCore.get_current_sim_time(clock)
        content_end = vi.last_t + seg_period
        if content_end > sim_t
            transmit_onboard!(
                onboard_live_queue,
                onboard_arch_queue,
                link,
                sim_t,
                run_dir;
                max_inflight_batches = max_inflight_batches,
            )
            wake = min(
                content_end,
                VirtualInstrument.segment_boundary(
                    vi.origin,
                    seg_period,
                    sim_t + Millisecond(1),
                ),
            )
            TelemetryCore.wait_until!(
                clock,
                wake;
                priority = TelemetryCore.EMITTER_PRIORITY,
            )
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
            recorder_full || (recorder_gap_start = pending[1].timestamp)
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
                hole_feed === nothing ||
                    recorder_gap_start === nothing ||
                    TelemetryCore.declare_gap_hole!(
                        hole_feed,
                        sim_t,
                        "recorder",
                        recorder_gap_start,
                        pending[1].timestamp,
                    )
                recorder_gap_start = nothing
                @info "[EMITTER] On-board recorder has room again: recording resumes at $(pending[1].timestamp)."
                recorder_full = false
            end
            # LIVE/ARCH follows the link state at finalization: flight
            # software marks data near-real-time only if the link is up
            # when it is ready to send. The content epoch is persisted
            # independently (metadata.json `content_epoch`,
            # masks/batch_epochs.csv), so pacing lag can shift the
            # classification but not the science provenance.
            is_live = ChannelEffects.is_transmittable(link, sim_t)
            # created_at = finalization instant on the mission timeline.
            batch = TelemetryCore.DataBatch(batch_counter, copy(pending), sim_t)
            batch_name = TelemetryCore.batch_name(batch_counter, is_live)
            batch_dir = joinpath(buffer_path, batch_name)

            stamp_markers!(
                batch_dir,
                batch,
                batch_name,
                run_dir,
                markers,
                vi.last_t;
                payload_row = VirtualInstrument.payload_row(vi, batch.segments[1].id),
            )

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
        end

        # 4. Transmission
        transmit_onboard!(
            onboard_live_queue,
            onboard_arch_queue,
            link,
            sim_t,
            run_dir;
            max_inflight_batches = max_inflight_batches,
        )
    end
    return nothing
end

end # module Emitter
