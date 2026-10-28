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
    pre_populate(instrument, start_sim_time, run_dir; batch_size, kwargs...) -> (instrument, pending_segments)

Fills the on-board recorder (`<run_dir>/onboard/`) with the `ARCH_` batches
produced during the initial downtime, the backlog the active mission window
starts with. `run_dir` is the absolute path of the run directory
([`TelemetryCore.run_directory`](@ref)).

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
  - `progress`: draw the progress bar on a terminal `stderr`; off for runs
    without a console, such as the members of a sweep.
"""
function pre_populate(
    instrument::VirtualInstrument.InstrumentState,
    start_sim_time::DateTime,
    run_dir::String;
    batch_size::Int,
    markers::Vector{TelemetryCore.EventMarker} = TelemetryCore.EventMarker[],
    generation_gaps::Vector{Tuple{DateTime,DateTime}} = Tuple{DateTime,DateTime}[],
    onboard_capacity_batches::Int = typemax(Int),
    hole_feed::Union{TelemetryCore.HoleFeed,Nothing} = nothing,
    progress::Bool = true,
)
    vi = instrument
    downtime_start = vi.last_t
    pending = TelemetryCore.DataSegment[]
    downtime_start < start_sim_time || return vi, pending
    downtime_days = (start_sim_time - downtime_start).value / TelemetryCore.MS_PER_DAY

    TelemetryCore.checked_run_dir(run_dir)
    buffer_path = joinpath(run_dir, "onboard")

    # Nothing leaves the buffer before the mission starts: the batches
    # written so far are the batches held, and an overflow gap opened here
    # stays open into run_emitter.
    held = 0
    recorder_gap = RecorderGap(nothing)

    @info "[EMITTER] Pre-populating onboard buffer for $(round(downtime_days, digits = 3)) days of downtime..."

    total_segs =
        ceil(Int, (start_sim_time - downtime_start).value / 1000 / vi.segment_duration_sec)

    # Carriage-return frames would fill the log of a detached run.
    @showprogress desc = "Pre-populating onboard buffer..." enabled =
        (progress && stderr isa Base.TTY) for _ in 1:total_segs
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

        length(pending) >= batch_size || continue
        if held >= onboard_capacity_batches
            discard_at_ceiling!(recorder_gap, run_dir, pending, held)
        else
            # The finalization instant is the content end, inside the blind
            # spot, as generation is instantaneous here.
            finalize_batch!(run_dir, held + 1, pending, vi.last_t, false, markers, vi)
            held += 1
        end
    end

    @info "[EMITTER] Pre-population complete. Buffered $held ARCH_ data batches."
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
    finalize_batch!(run_dir, id, pending, finalized_at, is_live, markers, vi;
                    onboard_count = nothing) -> String

Writes the segments of `pending` as batch `id` (`LIVE_` when `is_live`,
else `ARCH_`) into `<run_dir>/onboard/` with its markers
([`stamp_markers!`](@ref)), counts it in `onboard_count`, appends its `gen`
row at `finalized_at`, the finalization instant on the mission timeline,
and empties `pending`. Returns the batch name.
"""
function finalize_batch!(
    run_dir::String,
    id::Int,
    pending::Vector{TelemetryCore.DataSegment},
    finalized_at::DateTime,
    is_live::Bool,
    markers::Vector{TelemetryCore.EventMarker},
    vi::VirtualInstrument.InstrumentState;
    onboard_count::Union{Threads.Atomic{Int},Nothing} = nothing,
)
    batch = TelemetryCore.DataBatch(id, copy(pending), finalized_at)
    name = TelemetryCore.batch_name(id, is_live)
    stamp_markers!(
        joinpath(run_dir, "onboard", name),
        batch,
        name,
        run_dir,
        markers,
        vi.last_t;
        payload_row = VirtualInstrument.payload_row(vi, batch.segments[1].id),
    )
    onboard_count === nothing || Threads.atomic_add!(onboard_count, 1)
    TelemetryCore.log_tx_event(run_dir, finalized_at, name, "gen")
    empty!(pending)
    return name
end

"""
    RecorderGap

The open recorder-overflow gap: `start`, the content instant of the first
discarded segment, or `nothing` while the recorder has room.
"""
mutable struct RecorderGap
    start::Union{DateTime,Nothing}
end

"""
    discard_at_ceiling!(gap::RecorderGap, run_dir, pending, held::Int)

Discards the full batch in `pending` at the recorder ceiling of `held`
batches. No batch is evicted: new data is lost until a batch leaves for the
link. The first discard opens the gap with a `RECORDER` `gap_start` row in
`events_tx.csv`.
"""
function discard_at_ceiling!(
    gap::RecorderGap,
    run_dir::String,
    pending::Vector{TelemetryCore.DataSegment},
    held::Int,
)
    if gap.start === nothing
        start = pending[1].timestamp
        gap.start = start
        TelemetryCore.log_tx_event(run_dir, start, "RECORDER", "gap_start")
        @warn "[EMITTER] On-board recorder full ($held batches): new data is discarded until the buffer drains."
    end
    empty!(pending)
    return nothing
end

"""
    close_recorder_gap!(gap::RecorderGap, run_dir, resume::DateTime, declared_at::DateTime;
                        hole_feed = nothing)

Closes an open recorder gap at `resume`, the first content instant recorded
again: a `RECORDER` `gap_end` row, and with a `hole_feed` a `recorder` hole
declared at `declared_at`. Does nothing while no gap is open.
"""
function close_recorder_gap!(
    gap::RecorderGap,
    run_dir::String,
    resume::DateTime,
    declared_at::DateTime;
    hole_feed::Union{TelemetryCore.HoleFeed,Nothing} = nothing,
)
    start = gap.start
    start === nothing && return nothing
    TelemetryCore.log_tx_event(run_dir, resume, "RECORDER", "gap_end")
    hole_feed === nothing ||
        TelemetryCore.declare_gap_hole!(hole_feed, declared_at, "recorder", start, resume)
    gap.start = nothing
    @info "[EMITTER] On-board recorder has room again: recording resumes at $resume."
    return nothing
end

"""
    transmit_onboard!(live_queue, arch_queue, link, sim_t, run_dir; max_inflight_batches,
                      onboard_count = nothing) -> Int

Places on-board batches on the downlink while `link` is transmittable at
`sim_t` (visibility and no blackout). Free in-flight slots, the `link/`
listing below `max_inflight_batches` (a slot frees the moment the receiver
moves a batch out), are refilled from `live_queue` (FIFO, absolute
priority), then from `arch_queue` (held newest first, so the archive drains
LIFO). Each move from `onboard/` to `link/` is appended to `events_tx.csv`
as a `tx` row and taken off `onboard_count`. Returns the number of batches
placed.
"""
function transmit_onboard!(
    live_queue::Vector{String},
    arch_queue::Vector{String},
    link::ChannelEffects.LinkModel,
    sim_t::DateTime,
    run_dir::String;
    max_inflight_batches::Int,
    onboard_count::Union{Threads.Atomic{Int},Nothing} = nothing,
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
        onboard_count === nothing || Threads.atomic_sub!(onboard_count, 1)
        @info "[EMITTER] Tx ->| $next_batch ($reason)"
        TelemetryCore.log_tx_event(run_dir, sim_t, next_batch, "tx")
        link_count += 1
        placed += 1
    end
    return placed
end

# --- Emitter Main Loop ---
"""
    run_emitter(clock, link, run_dir, instrument; batch_size, kwargs...)

The spacecraft loop: segments from `instrument` (synthetic, or read from an
external CSV) are batched and placed on the downlink, live FIFO with
absolute priority over the archive LIFO ([`transmit_onboard!`](@ref)).
`link` is the composite [`ChannelEffects.LinkModel`](@ref) (visibility ×
disruption timeline): a batch finalized while the link is transmittable is
stamped `LIVE_`, any other `ARCH_`, so the batches generated during a
disruption blackout accumulate onboard. `run_dir` is the absolute path of
the run directory.

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
the horizon, on the stop flag, or on the `HALT` sentinel
([`TelemetryCore.loop_should_stop`](@ref)).

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
  - `onboard_count`: the number of batches on board, set from the census at
    start and kept in step with every write to and move out of `onboard/`;
    the receiver reads it for the metrics instead of listing the directory.
"""
function run_emitter(
    clock::TelemetryCore.TickClock,
    link::ChannelEffects.LinkModel,
    run_dir::String,
    instrument::VirtualInstrument.InstrumentState;
    batch_size::Int,
    pending_segments::Vector{TelemetryCore.DataSegment} = TelemetryCore.DataSegment[],
    stop::Union{Threads.Atomic{Bool},Nothing} = nothing,
    max_inflight_batches::Int = 5,
    markers::Vector{TelemetryCore.EventMarker} = TelemetryCore.EventMarker[],
    generation_gaps::Vector{Tuple{DateTime,DateTime}} = Tuple{DateTime,DateTime}[],
    onboard_capacity_batches::Int = typemax(Int),
    hole_feed::Union{TelemetryCore.HoleFeed,Nothing} = nothing,
    onboard_count::Threads.Atomic{Int} = Threads.Atomic{Int}(0),
)
    vi = instrument
    TelemetryCore.checked_run_dir(run_dir)
    buffer_path = joinpath(run_dir, "onboard")
    link_path = joinpath(run_dir, "link")
    foreach(mkpath, (buffer_path, link_path)) # idempotent: standalone/restart entry

    # The queues mirror onboard/, so the loop never lists it.
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
    onboard_count[] = length(onboard_live_queue) + length(onboard_arch_queue)
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
    # emitter: closed at the first finalization that finds room.
    recorder_gap = RecorderGap(TelemetryCore.open_recorder_gap_start(run_dir))

    @info "[EMITTER] Logic: near-real-time (NRT) FIFO priority + archive backfill (LIFO). Run: $(basename(run_dir))"

    seg_period = TelemetryCore.segment_period(vi.segment_duration_sec)
    transmit!(sim_t) = transmit_onboard!(
        onboard_live_queue,
        onboard_arch_queue,
        link,
        sim_t,
        run_dir;
        max_inflight_batches = max_inflight_batches,
        onboard_count = onboard_count,
    )

    while !TelemetryCore.loop_should_stop(clock, stop, halt_path, "[EMITTER]")
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
            transmit!(sim_t)
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

        # 3. Batch finalization, or discard at the recorder ceiling.
        held = length(onboard_live_queue) + length(onboard_arch_queue)
        if length(pending) >= batch_size && held >= onboard_capacity_batches
            discard_at_ceiling!(recorder_gap, run_dir, pending, held)
        elseif length(pending) >= batch_size
            close_recorder_gap!(
                recorder_gap,
                run_dir,
                pending[1].timestamp,
                sim_t;
                hole_feed = hole_feed,
            )
            # LIVE/ARCH follows the link state at finalization: flight
            # software marks data near-real-time only if the link is up
            # when it is ready to send. The content epoch is persisted
            # independently (metadata.json `content_epoch`,
            # masks/batch_epochs.csv), so pacing lag can shift the
            # classification but not the science provenance.
            is_live = ChannelEffects.is_transmittable(link, sim_t)
            content_start = pending[1].timestamp
            batch_name = finalize_batch!(
                run_dir,
                batch_counter,
                pending,
                sim_t,
                is_live,
                markers,
                vi;
                onboard_count = onboard_count,
            )
            if is_live
                # LIVE queue is FIFO: append at the tail, drain from the head.
                push!(onboard_live_queue, batch_name)
            else
                # ARCH queue is LIFO: insert at the head so popfirst! yields newest-first.
                pushfirst!(onboard_arch_queue, batch_name)
            end
            @info "[EMITTER] Gen  | $batch_name @ SimTime: $content_start"
            batch_counter += 1
        end

        # 4. Transmission
        transmit!(sim_t)
    end
    return nothing
end

end # module Emitter
