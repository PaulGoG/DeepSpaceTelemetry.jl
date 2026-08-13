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
    pre_populate(start_sim_time, run_id; ...) -> (instrument, leftover_segments)

Simulates satellite downtime prior to the start of the active mission window.
Fills the onboard SSD buffer with archived data batches to create a starting backlog.

Returns the `InstrumentState` used for generation together with any trailing
segments that did not fill a complete batch. Both must be handed to
[`run_emitter`](@ref) so that the data stream (in particular an external CSV
consumed via `ext_index`) continues seamlessly instead of restarting at the
first sample.
"""
function pre_populate(
    start_sim_time::DateTime,
    run_id::String;
    sample_rate::Float64 = 1024.0,
    seg_dur::Float64 = 60.0,
    batch_size::Int = 15,
    initial_downtime_days::Float64 = 3.0,
    data_source::String = "synthetic",
    ext_path::String = "",
    rng::Random.AbstractRNG = Xoshiro(0),
    signal_injection_probability::Float64 = 0.02,
)
    downtime_ms = max(0, round(Int, initial_downtime_days * 86_400_000))
    downtime_start = start_sim_time - Millisecond(downtime_ms)

    vi = VirtualInstrument.InstrumentState(
        downtime_start,
        sample_rate,
        seg_dur,
        data_source,
        ext_path;
        rng = rng,
        signal_injection_probability = signal_injection_probability,
    )
    current_batch_segs = TelemetryCore.DataSegment[]

    if initial_downtime_days <= 0.0
        return vi, current_batch_segs
    end

    run_dir = TelemetryCore.run_directory(run_id)
    buffer_path = joinpath(run_dir, "onboard")

    batch_counter = 1

    @info "[EMITTER] Pre-populating onboard buffer for $(initial_downtime_days) days of downtime..."

    total_segs = ceil(Int, (start_sim_time - downtime_start).value / 1000 / seg_dur)

    @showprogress "Pre-populating onboard buffer..." for _ in 1:total_segs
        if vi.last_t >= start_sim_time
            break
        end
        seg = VirtualInstrument.next_segment!(vi)
        push!(current_batch_segs, seg)

        if length(current_batch_segs) >= batch_size
            # created_at carries mission time (the generation epoch of the
            # batch's first segment), never wall-clock time: metadata.json is
            # persisted provenance and must live on the mission timeline.
            batch = TelemetryCore.DataBatch(
                batch_counter,
                copy(current_batch_segs),
                current_batch_segs[1].timestamp,
            )
            batch_name = "ARCH_batch_$batch_counter"
            batch_dir = joinpath(buffer_path, batch_name)

            TelemetryCore.save_batch(batch_dir, batch)
            # Ground-truth milestone: generation time = first segment timestamp
            # (inside the blind spot, i.e. before mission start).
            TelemetryCore.log_tx_event(
                run_dir,
                batch.segments[1].timestamp,
                batch_name,
                "gen",
            )
            empty!(current_batch_segs)
            batch_counter += 1
        end
    end

    @info "[EMITTER] Pre-population complete. Buffered $(batch_counter-1) ARCH_ data batches."
    return vi, current_batch_segs
end

# --- Emitter Main Loop ---
"""
    run_emitter(clock, link, run_id; ...)

The main satellite payload loop. Continuously generates scientific data (or reads from external CSV),
packages it into batches, and manages the DSN transmission queue using strict priority logic
(Live FIFO > Archive LIFO).

`link` is the composite [`ChannelEffects.LinkModel`](@ref) (visibility ×
disruption timeline): batches are stamped `LIVE_` and transmitted only while
the link is transmittable — during a disruption blackout the satellite keeps
generating `ARCH_` batches that accumulate onboard.

Pass the `instrument` and `initial_segments` returned by [`pre_populate`](@ref)
to continue the pre-populated data stream without gaps or duplication; when
`instrument === nothing` a fresh `InstrumentState` starting at
`clock.start_sim_time` is created instead (seeded by `rng`).
"""
function run_emitter(
    clock::TelemetryCore.SimulationClock,
    link::ChannelEffects.LinkModel,
    run_id::String;
    test_duration_sec::Float64 = 0.0,
    sample_rate::Float64 = 1024.0,
    seg_dur::Float64 = 60.0,
    batch_size::Int = 15,
    data_source::String = "synthetic",
    ext_path::String = "",
    instrument::Union{VirtualInstrument.InstrumentState,Nothing} = nothing,
    initial_segments::Vector{TelemetryCore.DataSegment} = TelemetryCore.DataSegment[],
    rng::Random.AbstractRNG = Xoshiro(0),
    deadline::Union{DateTime,Nothing} = nothing,
    stop::Union{Threads.Atomic{Bool},Nothing} = nothing,
    heartbeat_path::Union{String,Nothing} = nothing,
    max_inflight_batches::Int = 5,
    signal_injection_probability::Float64 = 0.02,
)
    # A fresh instrument anchors at the *current* mission time, not the
    # mission epoch: on a mid-mission restart the outage becomes an honest
    # generation gap instead of a replayed stream.
    vi =
        instrument === nothing ?
        VirtualInstrument.InstrumentState(
            TelemetryCore.get_current_sim_time(clock),
            sample_rate,
            seg_dur,
            data_source,
            ext_path;
            rng = rng,
            signal_injection_probability = signal_injection_probability,
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
    # would collide with batches already delivered downstream. tryparse
    # tolerates stray directories that merely share the prefix.
    batch_id = x -> something(tryparse(Int, split(x, "_")[end]), 0)
    all_onboard = filter(f -> isdir(joinpath(buffer_path, f)), readdir(buffer_path))
    archived = filter(f -> startswith(f, "ARCH_batch_"), all_onboard)
    sort!(archived, by = batch_id, rev = true) # LIFO internal
    append!(onboard_arch_queue, archived)
    stranded_live = filter(f -> startswith(f, "LIVE_batch_"), all_onboard)
    sort!(stranded_live, by = batch_id) # FIFO
    append!(onboard_live_queue, stranded_live)
    isempty(stranded_live) ||
        @info "[EMITTER] Re-attach: recovered $(length(stranded_live)) stranded LIVE batches."
    batch_counter =
        1 + max(
            isempty(all_onboard) ? 0 : maximum(batch_id, all_onboard),
            TelemetryCore.max_logged_batch_id(run_dir),
        )
    current_batch_segs = copy(initial_segments)
    halt_path = joinpath(run_dir, "HALT")
    last_heartbeat = now() - Second(2)

    @info "[EMITTER] Logic: near-real-time (NRT) FIFO priority + archive backfill (LIFO). Run: $run_id"

    start_wall_t = now()
    next_wall_t = start_wall_t

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
        if test_duration_sec > 0.0 &&
           (now() - start_wall_t).value / 1000.0 > test_duration_sec
            @info "[EMITTER] Test duration reached. Shutting down."
            break
        end
        if heartbeat_path !== nothing && (now() - last_heartbeat).value >= 1000
            touch(heartbeat_path)
            last_heartbeat = now()
        end

        # 1. Generation
        sim_t = TelemetryCore.get_current_sim_time(clock)
        seg = VirtualInstrument.next_segment!(vi)
        push!(current_batch_segs, seg)

        # 2. Batch Finalization
        if length(current_batch_segs) >= batch_size
            # Classification ruling: LIVE/ARCH follows the
            # link state at finalization time — flight software marks data
            # near-real-time only if the link is up when it is ready to send.
            # The payload's content epoch is preserved independently
            # (created_at + masks/batch_epochs.csv), so emitter pacing lag can
            # shift classification but never science provenance.
            is_live = ChannelEffects.is_transmittable(link, sim_t)
            # Mission-time provenance, matching the pre-population path.
            batch = TelemetryCore.DataBatch(batch_counter, copy(current_batch_segs), sim_t)
            prefix = is_live ? "LIVE_" : "ARCH_"
            batch_name = "$(prefix)batch_$batch_counter"
            batch_dir = joinpath(buffer_path, batch_name)

            TelemetryCore.save_batch(batch_dir, batch)

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
            empty!(current_batch_segs)
            batch_counter += 1
        end

        # 3. Transmission — gated on the effective link (visibility AND no blackout)
        if ChannelEffects.is_transmittable(link, sim_t)
            # Process ACKs efficiently
            acks = filter(f -> endswith(f, ".ack"), readdir(link_path))
            for ack in acks
                rm(joinpath(link_path, ack))
            end

            link_count =
                length(filter(f -> isdir(joinpath(link_path, f)), readdir(link_path)))

            if link_count < max_inflight_batches
                next_batch = ""
                reason = ""
                if !isempty(onboard_live_queue)
                    next_batch = popfirst!(onboard_live_queue) # FIFO for Live
                    reason = "Priority"
                elseif !isempty(onboard_arch_queue)
                    next_batch = popfirst!(onboard_arch_queue) # LIFO for Arch (since we pushfirst!)
                    reason = "Backfill"
                end
                if !isempty(next_batch)
                    TelemetryCore.backup_existing_dir(joinpath(link_path, next_batch))
                    mv(joinpath(buffer_path, next_batch), joinpath(link_path, next_batch))
                    @info "[EMITTER] Tx ->| $next_batch ($reason)"
                    TelemetryCore.log_tx_event(run_dir, sim_t, next_batch, "tx")
                end
            end
        end

        # 4. Precision Timing
        next_wall_t += Millisecond(round(Int, (vi.seg_dur / clock.speed_up) * 1000.0))
        wait_time = (next_wall_t - now()).value / 1000.0

        if wait_time > 0
            sleep(wait_time)
        end
    end
    # Heartbeat exists only while the loop runs: removing it tells the
    # watchdog this component finished rather than stalled.
    heartbeat_path !== nothing && rm(heartbeat_path; force = true)
end

end # module Emitter
