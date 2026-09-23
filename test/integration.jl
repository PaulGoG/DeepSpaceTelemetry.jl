# Integration: emitter and receiver run together on the mission clock — resilience, queuing, re-attachment, retention, pacing, light time, recorder ceiling.

@testset "Process-flow resilience (clock anchor + HALT)" begin
    # Anchor roundtrip: a re-attaching component reconstructs the identical clock
    mktempdir() do tmp
        clock = TelemetryCore.SimulationClock(
            DateTime(2026, 1, 1, 12),
            DateTime(2035, 1, 1, 6),
            3600.0,
        )
        deadline = DateTime(2026, 1, 1, 12, 5)
        TelemetryCore.save_clock_anchor(tmp, clock, deadline)
        restored = TelemetryCore.load_clock_anchor(tmp)
        @test restored.clock == clock
        @test restored.deadline == deadline
        @test_throws ArgumentError TelemetryCore.load_clock_anchor(joinpath(tmp, "absent"))
    end

    # HALT sentinel: both loops exit promptly, well before their duration
    halt_id = "TEST_RUN_halt_pid$(getpid())"
    mktempdir() do tmp
        ext_path = joinpath(tmp, "ext.csv")
        CSV.write(ext_path, DataFrame(Amplitude = Float32.(1:60_000)))
        cfg_stub = Dict{String,Any}(
            "simulation" => Dict{String,Any}(
                "speed_up" => 1800.0,
                "start_sim_time" => "2035-01-01T10:00:00",
            ),
        )
        halt_dir = TelemetryCore.setup_run_dir(halt_id; cfg = cfg_stub)
        try
            start_sim = DateTime(2035, 1, 1, 10)
            vis = TelemetryCore.VisibilityModel(Time(8), Second(8 * 3600), "flat")
            link = ChannelEffects.LinkModel(vis)
            vi, pending = with_logger(NullLogger()) do
                Emitter.pre_populate(
                    VirtualInstrument.InstrumentState(
                        Emitter.instrument_epoch(start_sim, 0.01),
                        4.0,
                        60.0,
                        "external",
                        ext_path,
                    ),
                    start_sim,
                    halt_id;
                    batch_size = 3,
                )
            end
            clock = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            em = Threads.@spawn with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    halt_id,
                    vi;
                    deadline = now() + Second(30),
                    batch_size = 3,
                    pending_segments = pending,
                )
            end
            rx = Threads.@spawn with_logger(NullLogger()) do
                Receiver.run_receiver(
                    clock,
                    link,
                    halt_id;
                    deadline = now() + Second(30),
                    orig_stdout = devnull,
                    batch_transfer_sec = 2.0,
                )
            end
            sleep(2.0)
            touch(joinpath(halt_dir, "HALT"))
            t_halt = time()
            wait(em)
            @test time() - t_halt < 10.0 # cooperative stop, not the 30 s duration
            # The receiver's exit path includes its finally-block plot
            # generation (Makie first-plot compilation): not latency-bounded.
            wait(rx)
            @test isfile(joinpath(halt_dir, "events_tx.csv"))
        finally
            rm(halt_dir; recursive = true, force = true)
        end
    end
end

@testset "Queuing parameters (in-flight cap and link floor)" begin
    # Emitter alone: no receiver ever ACKs, so link/ must saturate at exactly
    # the configured in-flight cap.
    cap_id = "TEST_RUN_cap_pid$(getpid())"
    mktempdir() do tmp
        ext_path = joinpath(tmp, "ext.csv")
        CSV.write(ext_path, DataFrame(Amplitude = Float32.(1:20_000)))
        cap_dir = TelemetryCore.setup_run_dir(
            cap_id;
            cfg = Dict{String,Any}(
                "simulation" => Dict{String,Any}(
                    "speed_up" => 1800.0,
                    "start_sim_time" => "2035-01-01T10:00:00",
                ),
            ),
        )
        try
            start_sim = DateTime(2035, 1, 1, 10)
            link = ChannelEffects.LinkModel(
                TelemetryCore.VisibilityModel(Time(8), Second(8 * 3600), "flat"),
            )
            vi, pending = with_logger(NullLogger()) do
                Emitter.pre_populate(
                    VirtualInstrument.InstrumentState(
                        Emitter.instrument_epoch(start_sim, 0.01),
                        4.0,
                        60.0,
                        "external",
                        ext_path,
                    ),
                    start_sim,
                    cap_id;
                    batch_size = 3,
                )
            end
            clock = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    cap_id,
                    vi;
                    deadline = now() + Second(3),
                    batch_size = 3,
                    pending_segments = pending,
                    max_inflight_batches = 2,
                )
            end
            n_link = length(
                filter(
                    f -> isdir(joinpath(cap_dir, "link", f)),
                    readdir(joinpath(cap_dir, "link")),
                ),
            )
            @test n_link == 2
        finally
            rm(cap_dir; recursive = true, force = true)
        end
    end

    # Receiver refuses transfers while effective capacity sits below the
    # configured floor: on the Gaussian wings nothing may reach ground/.
    floor_id = "TEST_RUN_floor_pid$(getpid())"
    mktempdir() do tmp
        ext_path = joinpath(tmp, "ext.csv")
        CSV.write(ext_path, DataFrame(Amplitude = Float32.(1:20_000)))
        floor_dir = TelemetryCore.setup_run_dir(
            floor_id;
            cfg = Dict{String,Any}(
                "simulation" => Dict{String,Any}(
                    "speed_up" => 1800.0,
                    "start_sim_time" => "2035-01-01T08:00:00",
                ),
            ),
        )
        try
            start_sim = DateTime(2035, 1, 1, 8) # session start: deep Gaussian wing
            link = ChannelEffects.LinkModel(
                TelemetryCore.VisibilityModel(Time(8), Second(8 * 3600), "gaussian"),
            )
            vi, pending = with_logger(NullLogger()) do
                Emitter.pre_populate(
                    VirtualInstrument.InstrumentState(
                        Emitter.instrument_epoch(start_sim, 0.01),
                        4.0,
                        60.0,
                        "external",
                        ext_path,
                    ),
                    start_sim,
                    floor_id;
                    batch_size = 3,
                )
            end
            clock = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            em = Threads.@spawn with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    floor_id,
                    vi;
                    deadline = now() + Second(4),
                    batch_size = 3,
                    pending_segments = pending,
                )
            end
            rx = Threads.@spawn with_logger(NullLogger()) do
                Receiver.run_receiver(
                    clock,
                    link,
                    floor_id;
                    deadline = now() + Second(4),
                    orig_stdout = devnull,
                    batch_transfer_sec = 2.0,
                    min_link_factor = 0.6,
                )
            end
            wait(em)
            wait(rx)
            ground = filter(
                f -> isdir(joinpath(floor_dir, "ground", f)),
                readdir(joinpath(floor_dir, "ground")),
            )
            pending = filter(
                f -> isdir(joinpath(floor_dir, "link", f)),
                readdir(joinpath(floor_dir, "link")),
            )
            @test isempty(ground)   # floor blocked every transfer
            @test !isempty(pending) # while the emitter kept pushing to the link
        finally
            rm(floor_dir; recursive = true, force = true)
        end
    end
end

@testset "Component re-attachment (restart contracts)" begin
    ra_id = "TEST_RUN_reattach_pid$(getpid())"
    mktempdir() do tmp
        ext_path = joinpath(tmp, "ext.csv")
        CSV.write(ext_path, DataFrame(Amplitude = Float32.(1:60_000)))
        ra_dir = TelemetryCore.setup_run_dir(
            ra_id;
            cfg = Dict{String,Any}(
                "simulation" => Dict{String,Any}(
                    "speed_up" => 1800.0,
                    "start_sim_time" => "2035-01-01T10:00:00",
                ),
            ),
        )
        try
            start_sim = DateTime(2035, 1, 1, 10)
            link = ChannelEffects.LinkModel(
                TelemetryCore.VisibilityModel(Time(8), Second(8 * 3600), "flat"),
            )
            vi, pending = with_logger(NullLogger()) do
                Emitter.pre_populate(
                    VirtualInstrument.InstrumentState(
                        Emitter.instrument_epoch(start_sim, 0.01),
                        4.0,
                        60.0,
                        "external",
                        ext_path,
                    ),
                    start_sim,
                    ra_id;
                    batch_size = 3,
                )
            end
            clock1 = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            TelemetryCore.save_clock_anchor(ra_dir, clock1, now() + Second(120))

            run_phase =
                (clk, instrument, segs) -> begin
                    em = Threads.@spawn with_logger(NullLogger()) do
                        Emitter.run_emitter(
                            clk,
                            link,
                            ra_id,
                            instrument;
                            deadline = now() + Second(3),
                            batch_size = 3,
                            pending_segments = segs,
                        )
                    end
                    rx = Threads.@spawn with_logger(NullLogger()) do
                        Receiver.run_receiver(
                            clk,
                            link,
                            ra_id;
                            deadline = now() + Second(3),
                            orig_stdout = devnull,
                            batch_transfer_sec = 2.0,
                        )
                    end
                    wait(em)
                    wait(rx)
                end

            run_phase(clock1, vi, pending)
            tx1 = CSV.read(joinpath(ra_dir, "events_tx.csv"), DataFrame)
            gens1 = [
                parse(Int, String(last(split(String(b), "_")))) for
                b in tx1[tx1.Event .== "gen", :Batch]
            ]
            max_phase1 = maximum(gens1)

            # Simulated component outage: supervisor-style gap bounds, then a
            # cold re-attachment that reconstructs the clock from the anchor
            # and takes a fresh instrument at the current mission time.
            restored = TelemetryCore.load_clock_anchor(ra_dir)
            TelemetryCore.log_tx_event(ra_dir, maximum(tx1.SimTime), "STREAM", "gap_start")
            TelemetryCore.log_tx_event(
                ra_dir,
                TelemetryCore.get_current_sim_time(restored.clock),
                "STREAM",
                "gap_end",
            )
            # Reconciliation seed: a batch delivered to ground/ whose
            # ingested record was lost to a crash window — the phase-2
            # receiver must synthesize the missing record at re-attach.
            orphan = joinpath(ra_dir, "ground", "ARCH_batch_500")
            mkpath(orphan)
            write(joinpath(orphan, "seg_1.csv"), "Amplitude\n0.0\n")

            run_phase(
                restored.clock,
                VirtualInstrument.InstrumentState(
                    TelemetryCore.get_current_sim_time(restored.clock),
                    4.0,
                    60.0,
                    "external",
                    ext_path,
                ),
                TelemetryCore.DataSegment[],
            )

            rx2 = CSV.read(joinpath(ra_dir, "events_rx.csv"), DataFrame)
            @test any((rx2.Event .== "ingested") .& (rx2.Batch .== "ARCH_batch_500"))

            tx2 = CSV.read(joinpath(ra_dir, "events_tx.csv"), DataFrame)
            gen_rows = tx2[tx2.Event .== "gen", :]
            gens = [parse(Int, String(last(split(String(b), "_")))) for b in gen_rows.Batch]
            @test length(gens) == length(unique(gens)) # no batch-ID collisions
            @test maximum(gens) > max_phase1           # generation resumed past phase 1
            @test issorted(gen_rows.SimTime)           # mission time continuous across the outage
            @test count(==("gap_start"), tx2.Event) == 1
            @test count(==("gap_end"), tx2.Event) == 1

            # Post-processing remains coherent with the gap events present.
            with_logger(NullLogger()) do
                Masks.generate_telemetry_masks(ra_dir)
            end
            @test isfile(joinpath(ra_dir, "masks", "telemetry_mask_timeline.csv"))
            # Epoch sidecar: finalization instant from the event log plus the
            # content epoch from each batch's metadata (the orphan seeded above
            # has no metadata and therefore no content epoch).
            epochs = CSV.read(joinpath(ra_dir, "masks", "batch_epochs.csv"), DataFrame)
            @test names(epochs) == ["Batch", "GenSimTime", "ContentEpoch"]
            @test any(!ismissing, epochs.ContentEpoch)
            @test all(
                ismissing(r.ContentEpoch) ||
                    DateTime(r.ContentEpoch) <= DateTime(r.GenSimTime) for
                r in eachrow(epochs)
            )
        finally
            rm(ra_dir; recursive = true, force = true)
        end
    end
end

@testset "Emitter → Receiver Integration (lossless)" begin
    # End-to-end miniature mission on external data: pre-population, live FIFO +
    # archive LIFO transmission, metrics, event logs, and mask generation. Uses
    # the real data/runs layout (paths are baked into the pipeline) and cleans up.
    run_id = "TEST_RUN_integration_pid$(getpid())"
    sample_rate = 4.0
    seg_dur = 60.0
    n_per_seg = round(Int, sample_rate * seg_dur)

    mktempdir() do tmp
        ext_path = joinpath(tmp, "ext_strain.csv")
        CSV.write(ext_path, DataFrame(Amplitude = Float32.(1:60_000)))

        cfg_stub = Dict{String,Any}(
            "simulation" => Dict{String,Any}(
                "speed_up" => 1800.0,
                "start_sim_time" => "2035-01-01T10:00:00",
            ),
            "telemetry" => Dict{String,Any}(
                "session_start" => "08:00:00",
                "session_duration_hours" => 8.0,
                "bandwidth_profile" => "flat",
            ),
        )
        run_dir = TelemetryCore.setup_run_dir(run_id; cfg = cfg_stub)
        try
            @test isfile(joinpath(run_dir, "config_snapshot.toml"))
            @test isdir(joinpath(run_dir, "lost"))

            start_sim = DateTime(2035, 1, 1, 10, 0, 0)
            vis = TelemetryCore.VisibilityModel(Time(8, 0, 0), Second(8 * 3600), "flat")
            link = ChannelEffects.LinkModel(vis)

            # 0.02 days = 1728 s of downtime -> 29 segments -> 9 full batches + 2 pending
            vi, pending = with_logger(NullLogger()) do
                Emitter.pre_populate(
                    VirtualInstrument.InstrumentState(
                        Emitter.instrument_epoch(start_sim, 0.02),
                        sample_rate,
                        seg_dur,
                        "external",
                        ext_path,
                    ),
                    start_sim,
                    run_id;
                    batch_size = 3,
                )
            end

            arch_batches = filter(
                f -> startswith(f, "ARCH_batch_"),
                readdir(joinpath(run_dir, "onboard")),
            )
            @test length(arch_batches) == 9
            @test vi.last_t >= start_sim
            # Stream continuity: instrument consumed exactly 29 segments...
            @test vi.source.index == 29 * n_per_seg + 1
            # ...and the partial batch carries segments 28-29 for the main loop
            @test length(pending) == 2
            @test pending[1].data[1] == Float32(27 * n_per_seg + 1)

            clock = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            em = Threads.@spawn with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    run_id,
                    vi;
                    deadline = now() + Second(6),
                    batch_size = 3,
                    pending_segments = pending,
                )
            end
            rx = Threads.@spawn with_logger(NullLogger()) do
                Receiver.run_receiver(
                    clock,
                    link,
                    run_id;
                    deadline = now() + Second(6),
                    orig_stdout = devnull,
                    batch_transfer_sec = 2.0,
                )
            end
            wait(em)
            wait(rx)

            ground = readdir(joinpath(run_dir, "ground"))
            @test !isempty(ground)
            @test any(f -> startswith(f, "LIVE_"), ground)  # live FIFO stream flowed
            @test any(f -> startswith(f, "ARCH_"), ground)  # backlog was backfilled
            @test isfile(joinpath(run_dir, "mission_profile.csv"))
            @test isempty(readdir(joinpath(run_dir, "lost"))) # NoLoss: nothing lost

            # Ground-truth event logs exist and are consistent
            @test isfile(joinpath(run_dir, "events_tx.csv"))
            tx_events = CSV.read(joinpath(run_dir, "events_tx.csv"), DataFrame)
            @test all(e -> e in ("gen", "tx"), tx_events.Event)
            rx_events = CSV.read(joinpath(run_dir, "events_rx.csv"), DataFrame)
            @test all(==("ingested"), rx_events.Event)
            @test nrow(rx_events) == length(ground)

            # Conservation: every generated batch is in exactly one place
            n_gen = count(==("gen"), tx_events.Event)
            n_onboard = length(
                filter(
                    f -> isdir(joinpath(run_dir, "onboard", f)),
                    readdir(joinpath(run_dir, "onboard")),
                ),
            )
            n_link = length(
                filter(
                    f -> isdir(joinpath(run_dir, "link", f)),
                    readdir(joinpath(run_dir, "link")),
                ),
            )
            @test n_gen == n_onboard + n_link + length(ground)

            Masks.generate_telemetry_masks(run_dir)
            mask_path = joinpath(run_dir, "masks", "telemetry_mask_timeline.csv")
            @test isfile(mask_path)
            mask_df = CSV.read(mask_path, DataFrame)
            @test nrow(mask_df) > 0
            for col in names(mask_df)
                col == "SimTime" && continue
                @test all(v -> v in (0, 1, 2, 3), mask_df[!, col]) # lossless run: no state 4
            end
            # Batches only ever move forward: Future -> Onboard -> Link -> Ground
            for col in names(mask_df)
                col == "SimTime" && continue
                @test issorted(mask_df[!, col])
            end

            # Estimator upper bounds hold against the realized artifacts of
            # this very mission (a safety gate that undercounts is worse
            # than none).
            est = TelemetryCore.estimate_artifacts(
                Dict{String,Any}(
                    "simulation" => Dict{String,Any}(
                        "speed_up" => 1800.0,
                        "mission_wall_seconds" => 6.0,
                        "initial_downtime_days" => 0.02,
                        "start_sim_time" => "2035-01-01T10:00:00",
                    ),
                    "storage" => Dict{String,Any}("max_storage_gb" => 10.0),
                    "physics" => Dict{String,Any}(
                        "data_source" => "external",
                        "sample_rate" => 4.0,
                        "segment_duration_sec" => 60.0,
                        "batch_size" => 3,
                    ),
                    "post_processing" => Dict{String,Any}(
                        "generate_mask_timeline" => true,
                        "expand_to_pointwise_masks" => false,
                    ),
                ),
            )
            realized_files =
                sum(length(fs) + length(ds) for (_, ds, fs) in walkdir(run_dir))
            realized_payload = sum(
                filesize(joinpath(root, f)) for (root, _, fs) in walkdir(run_dir) for
                f in fs if startswith(f, "seg_");
                init = 0,
            )
            profile_rows =
                nrow(CSV.read(joinpath(run_dir, "mission_profile.csv"), DataFrame))
            @test realized_files <= est.file_count
            @test realized_payload <= est.payload_bytes
            @test profile_rows <= est.metrics_rows
        finally
            rm(run_dir; recursive = true, force = true)
        end
    end
end

@testset "Retention custodian (grace window + watermark pruning)" begin
    # Aggressive retention on a lossless miniature mission: watermark 0 forces
    # pruning of every delivered batch older than the grace window. Asserts
    # the payload/provenance split, the grace guarantee, and that the science
    # products (event replay, masks) are unaffected by pruning.
    run_id = "TEST_RUN_retention_pid$(getpid())"
    mktempdir() do tmp
        ext_path = joinpath(tmp, "ext_strain.csv")
        CSV.write(ext_path, DataFrame(Amplitude = Float32.(1:60_000)))
        cfg_stub = Dict{String,Any}(
            "simulation" => Dict{String,Any}(
                "speed_up" => 1800.0,
                "start_sim_time" => "2035-01-01T10:00:00",
            ),
        )
        run_dir = TelemetryCore.setup_run_dir(run_id; cfg = cfg_stub)
        try
            start_sim = DateTime(2035, 1, 1, 10, 0, 0)
            vis = TelemetryCore.VisibilityModel(Time(8, 0, 0), Second(8 * 3600), "flat")
            link = ChannelEffects.LinkModel(vis)
            vi, pending = with_logger(NullLogger()) do
                Emitter.pre_populate(
                    VirtualInstrument.InstrumentState(
                        Emitter.instrument_epoch(start_sim, 0.02),
                        4.0,
                        60.0,
                        "external",
                        ext_path,
                    ),
                    start_sim,
                    run_id;
                    batch_size = 3,
                )
            end
            clock = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            retention = TelemetryCore.RetentionPolicy(
                true,
                Millisecond(round(Int, 0.25 * 3_600_000)),
                0.0,
                64.0 * 1024^2,
            )
            em = Threads.@spawn with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    run_id,
                    vi;
                    deadline = now() + Second(6),
                    batch_size = 3,
                    pending_segments = pending,
                )
            end
            rx_task = Threads.@spawn with_logger(NullLogger()) do
                Receiver.run_receiver(
                    clock,
                    link,
                    run_id;
                    deadline = now() + Second(6),
                    orig_stdout = devnull,
                    batch_transfer_sec = 2.0,
                    retention = retention,
                )
            end
            wait(em)
            wait(rx_task)

            ground = filter(
                f -> isdir(joinpath(run_dir, "ground", f)),
                readdir(joinpath(run_dir, "ground")),
            )
            @test !isempty(ground)
            pruned = filter(b -> isfile(joinpath(run_dir, "ground", b, "PRUNED")), ground)
            @test !isempty(pruned)
            for b in pruned
                files = readdir(joinpath(run_dir, "ground", b))
                @test !any(f -> startswith(f, "seg_"), files) # payload deleted
                @test "metadata.json" in files                # provenance retained
            end

            rx_events = CSV.read(joinpath(run_dir, "events_rx.csv"), DataFrame)
            @test count(==("pruned"), rx_events.Event) == length(pruned)
            # Grace guarantee: ingest → prune gap ≥ grace_hours of mission time
            ingest_times = Dict(
                r.Batch => r.SimTime for r in eachrow(rx_events) if r.Event == "ingested"
            )
            for r in eachrow(rx_events)
                r.Event == "pruned" || continue
                @test (r.SimTime - ingest_times[r.Batch]).value >= 0.25 * 3.6e6
            end

            # Science products unaffected: pruning never regresses mask state 3
            with_logger(NullLogger()) do
                Masks.generate_telemetry_masks(run_dir)
            end
            mask_df = CSV.read(
                joinpath(run_dir, "masks", "telemetry_mask_timeline.csv"),
                DataFrame,
            )
            for col in names(mask_df)
                col == "SimTime" && continue
                @test issorted(mask_df[!, col])
            end
            for b in pruned
                id = parse(Int, split(b, "_")[end])
                @test mask_df[end, Symbol("Batch_$id")] == 3
            end
            @test isempty(readdir(joinpath(run_dir, "lost"))) # lost/ untouched
        finally
            rm(run_dir; recursive = true, force = true)
        end
    end
end

@testset "Emitter → Receiver Integration (total loss, deterministic)" begin
    # Bernoulli p = 1 makes every transfer attempt fail: with max_retries = 2
    # each batch is retried exactly twice and lost on the third attempt. The
    # whole loss path (retries, lost/ moves, acks, event log, mask state 4)
    # becomes exactly predictable.
    run_id = "TEST_RUN_lossy_pid$(getpid())"

    mktempdir() do tmp
        ext_path = joinpath(tmp, "ext_strain.csv")
        CSV.write(ext_path, DataFrame(Amplitude = Float32.(1:60_000)))

        cfg_stub = Dict{String,Any}(
            "simulation" => Dict{String,Any}(
                "speed_up" => 1800.0,
                "start_sim_time" => "2035-01-01T10:00:00",
            ),
            "telemetry" => Dict{String,Any}(
                "session_start" => "08:00:00",
                "session_duration_hours" => 8.0,
                "bandwidth_profile" => "flat",
            ),
        )
        run_dir = TelemetryCore.setup_run_dir(run_id; cfg = cfg_stub)
        try
            start_sim = DateTime(2035, 1, 1, 10, 0, 0)
            vis = TelemetryCore.VisibilityModel(Time(8, 0, 0), Second(8 * 3600), "flat")
            link = ChannelEffects.LinkModel(vis)
            loss = ChannelEffects.BernoulliLoss(1.0, StableRNG(5))

            vi, pending = with_logger(NullLogger()) do
                Emitter.pre_populate(
                    VirtualInstrument.InstrumentState(
                        Emitter.instrument_epoch(start_sim, 0.02),
                        4.0,
                        60.0,
                        "external",
                        ext_path,
                    ),
                    start_sim,
                    run_id;
                    batch_size = 3,
                )
            end

            clock = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            em = Threads.@spawn with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    run_id,
                    vi;
                    deadline = now() + Second(6),
                    batch_size = 3,
                    pending_segments = pending,
                )
            end
            rx = Threads.@spawn with_logger(NullLogger()) do
                Receiver.run_receiver(
                    clock,
                    link,
                    run_id;
                    deadline = now() + Second(6),
                    orig_stdout = devnull,
                    batch_transfer_sec = 2.0,
                    loss_model = loss,
                    max_retries = 2,
                )
            end
            wait(em)
            wait(rx)

            ground = readdir(joinpath(run_dir, "ground"))
            lost = filter(
                f -> isdir(joinpath(run_dir, "lost", f)),
                readdir(joinpath(run_dir, "lost")),
            )
            @test isempty(ground)   # p = 1: nothing ever gets through
            @test !isempty(lost)    # ...and the retry budget kept expiring

            # Event log: every batch that reached the link produced exactly
            # 2 retries followed by 1 loss (deterministic under p = 1)
            rx_events = CSV.read(joinpath(run_dir, "events_rx.csv"), DataFrame)
            @test !any(==("ingested"), rx_events.Event)
            lost_rows = filter(r -> r.Event == "lost", rx_events)
            @test all(==(3), lost_rows.Attempt)
            @test nrow(lost_rows) == length(lost)
            for b in lost_rows.Batch
                retries = filter(r -> r.Event == "retry" && r.Batch == b, rx_events)
                @test nrow(retries) == 2
                @test sort(retries.Attempt) == [1, 2]
            end

            # Lost batch directories preserve their data (never deleted)
            @test all(b -> isfile(joinpath(run_dir, "lost", b, "metadata.json")), lost)

            # Conservation across all four stages
            tx_events = CSV.read(joinpath(run_dir, "events_tx.csv"), DataFrame)
            n_gen = count(==("gen"), tx_events.Event)
            n_onboard = length(
                filter(
                    f -> isdir(joinpath(run_dir, "onboard", f)),
                    readdir(joinpath(run_dir, "onboard")),
                ),
            )
            n_link = length(
                filter(
                    f -> isdir(joinpath(run_dir, "link", f)),
                    readdir(joinpath(run_dir, "link")),
                ),
            )
            @test n_gen == n_onboard + n_link + length(ground) + length(lost)

            # Mask matrix carries terminal state 4 and stays monotone
            Masks.generate_telemetry_masks(run_dir)
            mask_df = CSV.read(
                joinpath(run_dir, "masks", "telemetry_mask_timeline.csv"),
                DataFrame,
            )
            saw_lost = false
            for col in names(mask_df)
                col == "SimTime" && continue
                @test all(v -> v in (0, 1, 2, 3, 4), mask_df[!, col])
                @test issorted(mask_df[!, col]) # 0→1→2→4 is still monotone
                saw_lost |= any(==(4), mask_df[!, col])
            end
            @test saw_lost
        finally
            rm(run_dir; recursive = true, force = true)
        end
    end
end

@testset "Emitter pacing anchored to the mission clock" begin
    # The generation schedule follows the mission clock: a segment is produced
    # once its content interval has elapsed, a late start is recovered by
    # catch-up, and the content epoch of the stream tracks mission time
    # within one period at the end of the run.
    pace_id = "TEST_RUN_pacing_pid$(getpid())"
    mktempdir() do tmp
        ext_path = joinpath(tmp, "ext.csv")
        CSV.write(ext_path, DataFrame(Amplitude = Float32.(1:200_000)))
        speed_up = 600.0 # 60 s segments → 100 ms wall period
        pace_dir = TelemetryCore.setup_run_dir(
            pace_id;
            cfg = Dict{String,Any}(
                "simulation" => Dict{String,Any}(
                    "speed_up" => speed_up,
                    "start_sim_time" => "2035-01-01T10:00:00",
                ),
            ),
        )
        try
            start_sim = DateTime(2035, 1, 1, 10)
            seg_dur = 60.0
            batch_size = 3
            link = ChannelEffects.LinkModel(
                TelemetryCore.VisibilityModel(Time(8), Second(8 * 3600), "flat"),
            )
            # No pre-population: the instrument anchors at the mission epoch.
            vi, pending = with_logger(NullLogger()) do
                Emitter.pre_populate(
                    VirtualInstrument.InstrumentState(
                        Emitter.instrument_epoch(start_sim, 0.0),
                        4.0,
                        seg_dur,
                        "external",
                        ext_path,
                    ),
                    start_sim,
                    pace_id;
                    batch_size = batch_size,
                )
            end
            clock = TelemetryCore.SimulationClock(now(), start_sim, speed_up)
            wall_span_ms = 4000
            deadline = clock.start_real_time + Millisecond(wall_span_ms)
            with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    pace_id,
                    vi;
                    batch_size = batch_size,
                    pending_segments = pending,
                    deadline = deadline,
                    max_inflight_batches = 1,
                )
            end
            mission_end = start_sim + Millisecond(round(Int, wall_span_ms * speed_up))
            batch_span = Second(round(Int, batch_size * seg_dur))
            period = Second(round(Int, seg_dur))

            epochs = TelemetryCore.batch_content_epochs(pace_dir)
            expected_batches =
                floor(Int, wall_span_ms * speed_up / 1000 / seg_dur / batch_size)
            @test length(epochs) >= 2 # the generation loop produced a stream

            # How many batches the run yields depends on the host keeping pace
            # with the accelerated clock: at speed_up = 600 one 60 s segment
            # must be synthesized and written every 100 ms, which a cold or
            # loaded machine misses — the regime the emitter itself reports
            # through EMITTER_LAG_WARN_SEC. Production rate is therefore a
            # precondition here and a measurement in bench/ (the per-segment
            # cost that sets it is physics/next_segment plus
            # io/batch_save_load); the epoch arithmetic and the causality
            # bounds below hold either way.
            kept_pace = length(epochs) >= expected_batches - 1
            kept_pace ||
                @warn "[TEST] Host did not keep pace with the accelerated clock; " *
                      "the end-of-span coverage and steady-state lag assertions are skipped." produced =
                    length(epochs) expected = expected_batches

            # Content coverage and causality: the stream ends within one batch
            # of mission end and never runs ahead of the clock.
            last_content_end = maximum(values(epochs)) + batch_span
            kept_pace && @test last_content_end > mission_end - batch_span - period
            @test last_content_end <= mission_end + period

            # Metadata contract: content_epoch is the first-sample timestamp
            # (segment index arithmetic) and created_at is the finalization
            # instant, never earlier than the content end.
            locate(name) = first(
                d for d in
                (joinpath(pace_dir, "onboard", name), joinpath(pace_dir, "link", name)) if
                isdir(d)
            )
            lags = Dict{Int,Millisecond}()
            for (name, epoch) in epochs
                dir = locate(name)
                meta = TelemetryCore.read_batch_metadata(dir)
                first_idx = minimum(
                    parse(Int, match(r"seg_(\d+)\.csv", f).captures[1]) for
                    f in readdir(dir) if startswith(f, "seg_")
                )
                @test epoch == start_sim + Second((first_idx - 1) * round(Int, seg_dur))
                created = DateTime(meta["created_at"])
                @test created >= epoch + batch_span
                lags[Int(meta["batch_id"])] = created - (epoch + batch_span)
            end
            # Steady state: the last finalized batch lags the clock by less
            # than two periods (startup compilation is recovered by catch-up).
            kept_pace && @test lags[maximum(keys(lags))] < 2 * Millisecond(period)
        finally
            rm(pace_dir; recursive = true, force = true)
        end
    end
end

@testset "Round-trip light time defers retransmissions" begin
    tel = TelemetryCore.telemetry_settings(
        Dict{String,Any}("telemetry" => Dict{String,Any}("range_million_km" => 50.0)),
    )
    @test tel.round_trip_light_time_sec ≈ 2 * 50e9 / TelemetryCore.C_LIGHT rtol = 1e-12
    @test TelemetryCore.telemetry_settings(Dict{String,Any}()).round_trip_light_time_sec ==
          0.0
    @test_throws ArgumentError TelemetryCore.telemetry_settings(
        Dict{String,Any}("telemetry" => Dict{String,Any}("range_million_km" => -1.0)),
    )

    # Two live batches on the link; the first attempt on batch 1 is lost.
    # With a round trip, batch 2 is served while batch 1 waits and batch 1
    # arrives no earlier than one round trip after the loss; without it,
    # batch 1 is retried at once and lands before batch 2.
    function light_time_run(round_trip_sec)
        run_id = "TEST_RUN_rtlt_$(round(Int, round_trip_sec))_pid$(getpid())"
        run_dir = TelemetryCore.setup_run_dir(
            run_id;
            cfg = Dict{String,Any}(
                "simulation" => Dict{String,Any}(
                    "speed_up" => 600.0,
                    "start_sim_time" => "2035-01-01T10:00:00",
                ),
            ),
        )
        try
            start_sim = DateTime(2035, 1, 1, 10)
            for id in (1, 2)
                name = TelemetryCore.batch_name(id, true)
                seg = TelemetryCore.DataSegment(id, start_sim, Float32[0.0, 1.0])
                TelemetryCore.save_batch(
                    joinpath(run_dir, "link", name),
                    TelemetryCore.DataBatch(id, [seg], start_sim),
                )
                TelemetryCore.log_tx_event(run_dir, start_sim, name, "gen")
                TelemetryCore.log_tx_event(run_dir, start_sim, name, "tx")
            end
            link = ChannelEffects.LinkModel(
                TelemetryCore.VisibilityModel(Time(0), Second(24 * 3600), "flat"),
            )
            clock = TelemetryCore.SimulationClock(now(), start_sim, 600.0)
            loss = FirstAttemptLoss(TelemetryCore.batch_name(1, true), Ref(false))
            with_logger(NullLogger()) do
                Receiver.run_receiver(
                    clock,
                    link,
                    run_id;
                    orig_stdout = devnull,
                    batch_transfer_sec = 1.0,
                    loss_model = loss,
                    max_retries = 3,
                    deadline = now() + Second(3),
                    round_trip_light_time_sec = round_trip_sec,
                )
            end
            rx = CSV.read(joinpath(run_dir, "events_rx.csv"), DataFrame)
            return [
                (String(r.Batch), String(r.Event), DateTime(r.SimTime)) for r in eachrow(rx)
            ]
        finally
            rm(run_dir; recursive = true, force = true)
        end
    end
    events = light_time_run(600.0)
    retry_1 = findfirst(e -> e[1] == "LIVE_batch_1" && e[2] == "retry", events)
    ingest_2 = findfirst(e -> e[1] == "LIVE_batch_2" && e[2] == "ingested", events)
    ingest_1 = findfirst(e -> e[1] == "LIVE_batch_1" && e[2] == "ingested", events)
    @test retry_1 !== nothing && ingest_2 !== nothing && ingest_1 !== nothing
    @test retry_1 < ingest_2 < ingest_1
    @test events[ingest_1][3] - events[retry_1][3] >= Second(600)

    events0 = light_time_run(0.0)
    retry_1 = findfirst(e -> e[1] == "LIVE_batch_1" && e[2] == "retry", events0)
    ingest_2 = findfirst(e -> e[1] == "LIVE_batch_2" && e[2] == "ingested", events0)
    ingest_1 = findfirst(e -> e[1] == "LIVE_batch_1" && e[2] == "ingested", events0)
    @test retry_1 < ingest_1 < ingest_2
end

@testset "Scheduled generation gaps and the on-board recorder" begin
    base = valid_test_cfg()
    base["simulation"]["start_sim_time"] = "2035-01-01T10:00:00"
    cfg = deepcopy(base)
    cfg["disruption"] = Dict{String,Any}(
        "events" => Any[
            Dict{String,Any}(
                "type" => "solar_flare",
                "start_day" => 1.0,
                "duration_hours" => 2.0,
            ),
            Dict{String,Any}(
                "type" => "antenna_repointing",
                "start_day" => 0.5,
                "duration_hours" => 0.25,
            ),
            Dict{String,Any}(
                "type" => "maintenance",
                "affects" => "generation",
                "start_day" => 2.0,
                "duration_hours" => 1.0,
            ),
        ],
    )
    events = TelemetryCore.disruption_event_settings(cfg)
    @test [e.affects for e in events] == ["link", "generation", "generation"]
    start = DateTime(2035, 1, 1, 10)
    gaps = ChannelEffects.generation_gaps(cfg, start)
    @test gaps == [
        (start + Hour(12), start + Hour(12) + Minute(15)),
        (start + Day(2), start + Day(2) + Hour(1)),
    ]
    @test length(ChannelEffects.build_disruption_timeline(cfg, start).events) == 1
    @test TelemetryCore.validate_config(cfg) isa AbstractDict
    bad = deepcopy(base)
    bad["disruption"] = Dict{String,Any}(
        "events" => Any[Dict{String,Any}("affects" => "payload", "start_day" => 0.0)],
    )
    @test_throws ArgumentError TelemetryCore.disruption_event_settings(bad)

    # Recorder capacity: 14 days of 10-minute batches; gigabit only with rates.
    capacity = TelemetryCore.onboard_capacity(base)
    @test capacity.days == 14.0 && capacity.batches == 2016 && isnan(capacity.gigabit)
    rates = deepcopy(base)
    delete!(rates["telemetry"], "max_batches_per_hour")
    rates["telemetry"]["downlink_kbps"] = 230.0
    rates["telemetry"]["onboard_data_rate_kbps"] = 75.0
    @test TelemetryCore.onboard_capacity(rates).gigabit ≈ 14 * 86_400 * 75 / 1e6 rtol =
        1e-12
    small = deepcopy(base)
    small["storage"] = Dict{String,Any}("onboard_capacity_days" => 0.0)
    @test_throws ArgumentError TelemetryCore.onboard_capacity(small)
    # The nightly 16 h without contact exceeds a 0.5-day recorder; a 3-day
    # blind spot exceeds a 2-day recorder.
    tight = deepcopy(base)
    tight["storage"] = Dict{String,Any}("onboard_capacity_days" => 0.5)
    tight["simulation"]["mission_wall_seconds"] = 30.0 # 30 h: spans the 16 h night
    @test_logs (:warn, r"longest interval without ground contact") match_mode = :any TelemetryCore.validate_config(
        tight,
    )
    blind = deepcopy(base)
    blind["storage"] = Dict{String,Any}("onboard_capacity_days" => 2.0)
    blind["simulation"]["initial_downtime_days"] = 3.0
    blind["simulation"]["mission_wall_seconds"] = 1.0
    @test_logs (:warn, r"initial_downtime_days = 3.0 exceeds") match_mode = :any TelemetryCore.validate_config(
        blind,
    )

    # Pre-population through a scheduled gap: the incomplete batch at the
    # gap start is discarded and the gap is bounded in events_tx.csv.
    gap_id = "TEST_RUN_gap_pid$(getpid())"
    gap_dir = TelemetryCore.setup_run_dir(gap_id; cfg = base)
    try
        gap = (start - Minute(10), start - Minute(6))
        with_logger(NullLogger()) do
            Emitter.pre_populate(
                VirtualInstrument.InstrumentState(
                    Emitter.instrument_epoch(start, 0.01),
                    4.0,
                    60.0,
                    "synthetic",
                    "",
                ),
                start,
                gap_id;
                batch_size = 3,
                generation_gaps = [gap],
            )
        end
        tx = CSV.read(joinpath(gap_dir, "events_tx.csv"), DataFrame)
        gap_rows = tx[tx.Batch .== "SCHEDULED", :]
        @test String.(gap_rows.Event) == ["gap_start", "gap_end"]
        # Segments at −14.4, −13.4, −12.4 min form batch 1; −11.4 and −10.4
        # are pending when −9.4 falls inside the gap and are discarded.
        @test DateTime(gap_rows.SimTime[1]) == start - Minute(11) - Second(24)
        @test DateTime(gap_rows.SimTime[2]) == start - Minute(6)
        @test TelemetryCore.max_logged_batch_id(gap_dir) == 3
        @test TelemetryCore.batch_content_epochs(gap_dir)["ARCH_batch_2"] ==
              start - Minute(6)
    finally
        rm(gap_dir; recursive = true, force = true)
    end

    # Recorder ceiling during pre-population: two batches fit, the rest of
    # the blind spot is discarded behind an open RECORDER gap.
    rec_id = "TEST_RUN_recorder_pid$(getpid())"
    rec_dir = TelemetryCore.setup_run_dir(rec_id; cfg = base)
    try
        with_logger(NullLogger()) do
            Emitter.pre_populate(
                VirtualInstrument.InstrumentState(
                    Emitter.instrument_epoch(start, 0.01),
                    4.0,
                    60.0,
                    "synthetic",
                    "",
                ),
                start,
                rec_id;
                batch_size = 3,
                onboard_capacity_batches = 2,
            )
        end
        @test TelemetryCore.max_logged_batch_id(rec_dir) == 2
        tx = CSV.read(joinpath(rec_dir, "events_tx.csv"), DataFrame)
        rec_rows = tx[tx.Batch .== "RECORDER", :]
        @test String.(rec_rows.Event) == ["gap_start"]
        @test DateTime(rec_rows.SimTime[1]) == start - Minute(8) - Second(24)
        @test TelemetryCore.open_recorder_gap(rec_dir)
        @test MissionFigures.generation_gap_spans(
            rec_dir,
            start - Hour(1),
            5.0,
            "RECORDER",
        ) == [(1 - 8.4 / 60, 5.0)]
        @test isempty(MissionFigures.generation_gap_spans(rec_dir, start, 5.0, "SCHEDULED"))
    finally
        rm(rec_dir; recursive = true, force = true)
    end

    # Mission phase at the ceiling with the link down: every batch beyond
    # the second is discarded and the overflow gap stays open.
    live_id = "TEST_RUN_recorder_live_pid$(getpid())"
    live_dir = TelemetryCore.setup_run_dir(live_id; cfg = base)
    try
        link = ChannelEffects.LinkModel(
            TelemetryCore.VisibilityModel(Time(0), Second(3600), "flat"),
        )
        clock = TelemetryCore.SimulationClock(now(), start, 1800.0)
        with_logger(NullLogger()) do
            Emitter.run_emitter(
                clock,
                link,
                live_id,
                VirtualInstrument.InstrumentState(
                    TelemetryCore.get_current_sim_time(clock),
                    4.0,
                    60.0,
                    "synthetic",
                    "",
                );
                deadline = now() + Second(3),
                batch_size = 3,
                onboard_capacity_batches = 2,
            )
        end
        @test TelemetryCore.max_logged_batch_id(live_dir) == 2
        tx = CSV.read(joinpath(live_dir, "events_tx.csv"), DataFrame)
        @test String.(tx[tx.Batch .== "RECORDER", :Event]) == ["gap_start"]
        @test count(
            isdir,
            joinpath.(
                joinpath(live_dir, "onboard"),
                readdir(joinpath(live_dir, "onboard")),
            ),
        ) == 2
    finally
        rm(live_dir; recursive = true, force = true)
    end
end
