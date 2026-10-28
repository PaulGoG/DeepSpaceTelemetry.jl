# Integration: emitter and receiver run together on the mission clock — resilience, queuing, re-attachment, retention, pacing, light time, recorder ceiling.

@testset "Process-flow resilience (clock anchor + HALT)" begin
    # Anchor roundtrip: a paced clock reads back with its epochs, horizon,
    # pace, and the nominal wall end of its budget (one day at 3600x: 24 s).
    mktempdir() do tmp
        clock = TelemetryCore.TickClock(
            DateTime(2035, 1, 1, 6),
            DateTime(2035, 1, 2, 6);
            wall_epoch = DateTime(2026, 1, 1, 12),
            pace = 3600.0,
        )
        TelemetryCore.save_clock_anchor(tmp, clock)
        restored = TelemetryCore.load_clock_anchor(tmp)
        @test restored.mode == "wall"
        @test restored.start_sim_time == clock.start_sim_time
        @test restored.wall_epoch == clock.wall_epoch
        @test restored.horizon == clock.horizon
        @test restored.speed_up == 3600.0
        @test restored.deadline_wall == clock.wall_epoch + Second(24)
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
                    TelemetryCore.run_directory(halt_id);
                    batch_size = 3,
                )
            end
            # Paced at 1800x over 30 mission half-hours: a 30 s wall budget.
            clock = TelemetryCore.TickClock(
                start_sim,
                start_sim + Second(30 * 1800);
                pace = 1800.0,
            )
            driver = @async drive_components(
                clock;
                emitter = c -> Emitter.run_emitter(
                    c,
                    link,
                    TelemetryCore.run_directory(halt_id),
                    vi;
                    batch_size = 3,
                    pending_segments = pending,
                ),
                receiver = c -> Receiver.run_receiver(
                    c,
                    link,
                    TelemetryCore.run_directory(halt_id);
                    orig_stdout = devnull,
                    batch_transfer_sec = 2.0,
                ),
                should_stop = () -> isfile(joinpath(halt_dir, "HALT")),
            )
            sleep(2.0)
            touch(joinpath(halt_dir, "HALT"))
            t_halt = time()
            wait(driver)
            @test time() - t_halt < 10.0 # cooperative stop, not the 30 s duration
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
                    TelemetryCore.run_directory(cap_id);
                    batch_size = 3,
                )
            end
            clock = TelemetryCore.TickClock(start_sim, start_sim + Second(3 * 1800))
            drive_components(
                clock;
                emitter = c -> Emitter.run_emitter(
                    c,
                    link,
                    TelemetryCore.run_directory(cap_id),
                    vi;
                    batch_size = 3,
                    pending_segments = pending,
                    max_inflight_batches = 2,
                ),
            )
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
                    TelemetryCore.run_directory(floor_id);
                    batch_size = 3,
                )
            end
            clock = TelemetryCore.TickClock(start_sim, start_sim + Second(4 * 1800))
            drive_components(
                clock;
                emitter = c -> Emitter.run_emitter(
                    c,
                    link,
                    TelemetryCore.run_directory(floor_id),
                    vi;
                    batch_size = 3,
                    pending_segments = pending,
                ),
                receiver = c -> Receiver.run_receiver(
                    c,
                    link,
                    TelemetryCore.run_directory(floor_id);
                    orig_stdout = devnull,
                    batch_transfer_sec = 2.0,
                    min_link_factor = 0.6,
                ),
            )
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
        CSV.write(ext_path, DataFrame(Amplitude = Float32.(1:400_000)))
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
                    TelemetryCore.run_directory(ra_id);
                    batch_size = 3,
                )
            end
            clock1 = TelemetryCore.TickClock(start_sim, start_sim + Second(3 * 1800))
            TelemetryCore.save_clock_anchor(ra_dir, clock1)

            run_phase =
                (clk, instrument, segs) -> drive_components(
                    clk;
                    emitter = c -> Emitter.run_emitter(
                        c,
                        link,
                        TelemetryCore.run_directory(ra_id),
                        instrument;
                        batch_size = 3,
                        pending_segments = segs,
                    ),
                    receiver = c -> Receiver.run_receiver(
                        c,
                        link,
                        TelemetryCore.run_directory(ra_id);
                        orig_stdout = devnull,
                        batch_transfer_sec = 2.0,
                    ),
                )

            run_phase(clock1, vi, pending)
            tx1 = TelemetryCore.read_table(joinpath(ra_dir, "events_tx.csv"))
            gens1 = [
                parse(Int, String(last(split(String(b), "_")))) for
                b in tx1[tx1.Event .== "gen", :Batch]
            ]
            max_phase1 = maximum(gens1)

            # Simulated component outage: supervisor-style gap bounds, then a
            # cold re-attachment that reconstructs the clock from the anchor
            # and resumes the instrument where phase 1 ended, so mission time
            # is continuous.
            restored = TelemetryCore.load_clock_anchor(ra_dir)
            resumed_at = clock1.horizon
            clock2 = TelemetryCore.TickClock(
                resumed_at,
                resumed_at + Second(3 * 1800);
                wall_epoch = restored.wall_epoch,
            )
            resumed = VirtualInstrument.resumed(vi, resumed_at)
            Supervisor.record_generation_gap!(
                ra_dir,
                clock2,
                resumed.last_t;
                origin = vi.origin,
                sample_rate = 4.0,
                points_per_batch = 720,
            )
            # Reconciliation seed: a batch delivered to ground/ whose
            # ingested record was lost to a crash window — the phase-2
            # receiver must synthesize the missing record at re-attach.
            orphan = joinpath(ra_dir, "ground", "ARCH_batch_500")
            mkpath(orphan)
            write(joinpath(orphan, "seg_1.csv"), "Amplitude\n0.0\n")

            run_phase(clock2, resumed, TelemetryCore.DataSegment[])

            rx2 = TelemetryCore.read_table(joinpath(ra_dir, "events_rx.csv"))
            @test any((rx2.Event .== "ingested") .& (rx2.Batch .== "ARCH_batch_500"))

            tx2 = TelemetryCore.read_table(joinpath(ra_dir, "events_tx.csv"))
            gen_rows = tx2[tx2.Event .== "gen", :]
            gens = [parse(Int, String(last(split(String(b), "_")))) for b in gen_rows.Batch]
            @test length(gens) == length(unique(gens)) # no batch-ID collisions
            @test maximum(gens) > max_phase1           # generation resumed past phase 1
            @test issorted(gen_rows.SimTime)           # mission time continuous across the outage
            @test count(==("gap_start"), tx2.Event) == 1
            @test count(==("gap_end"), tx2.Event) == 1
            # The payload resumes at the rows of the resumed content instant.
            alignment = ramp_alignment(ra_dir, vi.origin, 4.0)
            @test alignment.checked == length(gens)
            @test isempty(alignment.misaligned) && isempty(alignment.repeated)

            # Post-processing remains coherent with the gap events present.
            with_logger(NullLogger()) do
                Masks.generate_telemetry_masks(ra_dir)
            end
            @test isfile(joinpath(ra_dir, "masks", "telemetry_mask_timeline.csv"))
            # Epoch sidecar: finalization instant from the event log plus the
            # content epoch from each batch's metadata (the orphan seeded above
            # has no metadata and therefore no content epoch).
            epochs = TelemetryCore.read_table(joinpath(ra_dir, "masks", "batch_epochs.csv"))
            @test names(epochs) == ["Batch", "GenSimTime", "ContentEpoch", "PayloadRow"]
            @test any(!ismissing, epochs.ContentEpoch)
            # The payload row of every batch is the one its content epoch implies.
            @test all(
                r.PayloadRow ==
                round(Int, (DateTime(r.ContentEpoch) - vi.origin).value / 1000 * 4.0) + 1
                for r in eachrow(epochs)
            )
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
                    TelemetryCore.run_directory(run_id);
                    batch_size = 3,
                )
            end

            arch_batches = filter(
                f -> startswith(f, "ARCH_batch_"),
                readdir(joinpath(run_dir, "onboard")),
            )
            @test length(arch_batches) == 9
            @test vi.last_t >= start_sim
            # Stream continuity: instrument produced exactly 29 segments...
            @test VirtualInstrument.segment_id(vi, vi.last_t) == 30
            # ...and the partial batch carries segments 28-29 for the main loop
            @test length(pending) == 2
            @test pending[1].data[1] == Float32(27 * n_per_seg + 1)

            clock = TelemetryCore.TickClock(start_sim, start_sim + Second(6 * 1800))
            drive_components(
                clock;
                emitter = c -> Emitter.run_emitter(
                    c,
                    link,
                    TelemetryCore.run_directory(run_id),
                    vi;
                    batch_size = 3,
                    pending_segments = pending,
                ),
                receiver = c -> Receiver.run_receiver(
                    c,
                    link,
                    TelemetryCore.run_directory(run_id);
                    orig_stdout = devnull,
                    batch_transfer_sec = 2.0,
                ),
            )

            ground = readdir(joinpath(run_dir, "ground"))
            @test !isempty(ground)
            @test any(f -> startswith(f, "LIVE_"), ground)  # live FIFO stream flowed
            @test any(f -> startswith(f, "ARCH_"), ground)  # backlog was backfilled
            @test isfile(joinpath(run_dir, "mission_profile.csv"))
            @test isempty(readdir(joinpath(run_dir, "lost"))) # NoLoss: nothing lost

            # Ground-truth event logs exist and are consistent
            @test isfile(joinpath(run_dir, "events_tx.csv"))
            tx_events = TelemetryCore.read_table(joinpath(run_dir, "events_tx.csv"))
            @test all(e -> e in ("gen", "tx"), tx_events.Event)
            rx_events = TelemetryCore.read_table(joinpath(run_dir, "events_rx.csv"))
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
            mask_df = TelemetryCore.read_table(mask_path)
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
                nrow(TelemetryCore.read_table(joinpath(run_dir, "mission_profile.csv")))
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
                    TelemetryCore.run_directory(run_id);
                    batch_size = 3,
                )
            end
            clock = TelemetryCore.TickClock(start_sim, start_sim + Second(6 * 1800))
            retention = TelemetryCore.RetentionPolicy(
                true,
                Millisecond(round(Int, 0.25 * 3_600_000)),
                0.0,
                64.0 * 1024^2,
            )
            feed = TelemetryCore.HoleFeed(
                run_dir,
                Emitter.instrument_epoch(start_sim, 0.02),
                4.0,
                720,
            )
            drive_components(
                clock;
                emitter = c -> Emitter.run_emitter(
                    c,
                    link,
                    TelemetryCore.run_directory(run_id),
                    vi;
                    batch_size = 3,
                    pending_segments = pending,
                ),
                receiver = c -> Receiver.run_receiver(
                    c,
                    link,
                    TelemetryCore.run_directory(run_id);
                    orig_stdout = devnull,
                    batch_transfer_sec = 2.0,
                    retention = retention,
                    hole_feed = feed,
                ),
            )

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

            rx_events = TelemetryCore.read_table(joinpath(run_dir, "events_rx.csv"))
            @test count(==("pruned"), rx_events.Event) == length(pruned)
            # Grace guarantee: ingest → prune gap ≥ grace_hours of mission time
            ingest_times = Dict(
                r.Batch => r.SimTime for r in eachrow(rx_events) if r.Event == "ingested"
            )
            for r in eachrow(rx_events)
                r.Event == "pruned" || continue
                @test (r.SimTime - ingest_times[r.Batch]).value >= 0.25 * 3.6e6
            end
            # The declared-hole feed carries every pruned batch at the instant of its pruned row.
            holes = TelemetryCore.read_hole_feed(run_dir)
            @test Set(skipmissing(holes.Batch)) == Set(pruned)
            @test all(==("pruned"), holes.Cause)
            @test all(holes.RowLast .- holes.RowFirst .+ 1 .== 720)
            for r in eachrow(rx_events)
                r.Event == "pruned" || continue
                @test any(
                    (coalesce.(holes.Batch, "") .== r.Batch) .&
                    (holes.DeclaredAt .== r.SimTime),
                )
            end

            # Science products unaffected: pruning never regresses mask state 3
            with_logger(NullLogger()) do
                Masks.generate_telemetry_masks(run_dir)
            end
            mask_df = TelemetryCore.read_table(
                joinpath(run_dir, "masks", "telemetry_mask_timeline.csv"),
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
                    TelemetryCore.run_directory(run_id);
                    batch_size = 3,
                )
            end

            clock = TelemetryCore.TickClock(start_sim, start_sim + Second(6 * 1800))
            feed = TelemetryCore.HoleFeed(
                run_dir,
                Emitter.instrument_epoch(start_sim, 0.02),
                4.0,
                720,
            )
            drive_components(
                clock;
                emitter = c -> Emitter.run_emitter(
                    c,
                    link,
                    TelemetryCore.run_directory(run_id),
                    vi;
                    batch_size = 3,
                    pending_segments = pending,
                ),
                receiver = c -> Receiver.run_receiver(
                    c,
                    link,
                    TelemetryCore.run_directory(run_id);
                    orig_stdout = devnull,
                    batch_transfer_sec = 2.0,
                    loss_model = loss,
                    max_retries = 2,
                    hole_feed = feed,
                ),
            )

            ground = readdir(joinpath(run_dir, "ground"))
            lost = filter(
                f -> isdir(joinpath(run_dir, "lost", f)),
                readdir(joinpath(run_dir, "lost")),
            )
            @test isempty(ground)   # p = 1: nothing ever gets through
            @test !isempty(lost)    # ...and the retry budget kept expiring

            # Event log: every batch that reached the link produced exactly
            # 2 retries followed by 1 loss (deterministic under p = 1)
            rx_events = TelemetryCore.read_table(joinpath(run_dir, "events_rx.csv"))
            @test !any(==("ingested"), rx_events.Event)
            lost_rows = filter(r -> r.Event == "lost", rx_events)
            @test all(==(3), lost_rows.Attempt)
            @test nrow(lost_rows) == length(lost)
            for b in lost_rows.Batch
                retries = filter(r -> r.Event == "retry" && r.Batch == b, rx_events)
                @test nrow(retries) == 2
                @test sort(retries.Attempt) == [1, 2]
            end
            # The declared-hole feed carries every lost batch at the instant of its lost row, on its stamped rows.
            holes = TelemetryCore.read_hole_feed(run_dir)
            @test Set(skipmissing(holes.Batch)) == Set(lost)
            @test all(==("lost"), holes.Cause)
            for r in eachrow(lost_rows)
                row = findfirst(==(r.Batch), coalesce.(holes.Batch, ""))
                @test row !== nothing && holes.DeclaredAt[row] == r.SimTime
                meta = TelemetryCore.read_batch_metadata(joinpath(run_dir, "lost", r.Batch))
                @test holes.RowFirst[row] == meta["payload_row"] &&
                      holes.RowLast[row] == meta["payload_row"] + 719
            end

            # Lost batch directories preserve their data (never deleted)
            @test all(b -> isfile(joinpath(run_dir, "lost", b, "metadata.json")), lost)

            # Conservation across all four stages
            tx_events = TelemetryCore.read_table(joinpath(run_dir, "events_tx.csv"))
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
            mask_df = TelemetryCore.read_table(
                joinpath(run_dir, "masks", "telemetry_mask_timeline.csv"),
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

@testset "Paced and unpaced runs produce the same record" begin
    # One emitter-only configuration, run unpaced and then paced at 600x over
    # a 4 s wall budget. The paced run takes at least its budget (a lagging
    # host may take longer, never shorter) and writes the same event log, as
    # pacing only delays the release of each logical instant.
    mktempdir() do tmp
        ext_path = joinpath(tmp, "ext.csv")
        CSV.write(ext_path, DataFrame(Amplitude = Float32.(1:200_000)))
        speed_up = 600.0 # 60 s segments, 100 ms wall period
        start_sim = DateTime(2035, 1, 1, 10)
        mission_end = start_sim + Second(4 * 600)
        seg_dur = 60.0
        batch_size = 3
        batch_span = Second(round(Int, batch_size * seg_dur))
        period = Second(round(Int, seg_dur))
        link = ChannelEffects.LinkModel(
            TelemetryCore.VisibilityModel(Time(8), Second(8 * 3600), "flat"),
        )
        run_dirs = String[]
        # Returns the run directory and the wall time of the driver.
        function pacing_run(label, pace)
            pace_id = "TEST_RUN_pacing_$(label)_pid$(getpid())"
            pace_dir = TelemetryCore.setup_run_dir(
                pace_id;
                cfg = Dict{String,Any}(
                    "simulation" => Dict{String,Any}(
                        "speed_up" => speed_up,
                        "start_sim_time" => "2035-01-01T10:00:00",
                    ),
                ),
            )
            push!(run_dirs, pace_dir)
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
                    TelemetryCore.run_directory(pace_id);
                    batch_size = batch_size,
                )
            end
            clock = TelemetryCore.TickClock(start_sim, mission_end; pace = pace)
            elapsed = @elapsed drive_components(
                clock;
                emitter = c -> Emitter.run_emitter(
                    c,
                    link,
                    TelemetryCore.run_directory(pace_id),
                    vi;
                    batch_size = batch_size,
                    pending_segments = pending,
                    max_inflight_batches = 1,
                ),
            )
            return pace_dir, elapsed
        end
        try
            unpaced_dir, _ = pacing_run("unpaced", nothing)
            pace_dir, elapsed_paced = pacing_run("paced", speed_up)
            @test 3.0 <= elapsed_paced <= 15.0
            @test read(joinpath(pace_dir, "events_tx.csv"), String) ==
                  read(joinpath(unpaced_dir, "events_tx.csv"), String)

            epochs = TelemetryCore.batch_content_epochs(pace_dir)
            @test length(epochs) >= 2 # the generation loop produced a stream

            # Content coverage and causality: the stream ends within one batch
            # of mission end and never runs ahead of the clock.
            last_content_end = maximum(values(epochs)) + batch_span
            @test last_content_end > mission_end - batch_span - period
            @test last_content_end <= mission_end + period

            # Metadata contract: content_epoch is the first-sample timestamp
            # (segment index arithmetic) and created_at is the finalization
            # instant, never earlier than the content end.
            locate(name) = first(
                d for d in
                (joinpath(pace_dir, "onboard", name), joinpath(pace_dir, "link", name)) if
                isdir(d)
            )
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
            end
        finally
            foreach(d -> rm(d; recursive = true, force = true), run_dirs)
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
            clock = TelemetryCore.TickClock(start_sim, start_sim + Second(3 * 600))
            loss = FirstAttemptLoss(Ref(false))
            drive_components(
                clock;
                receiver = c -> Receiver.run_receiver(
                    c,
                    link,
                    TelemetryCore.run_directory(run_id);
                    orig_stdout = devnull,
                    batch_transfer_sec = 1.0,
                    loss_model = loss,
                    max_retries = 3,
                    round_trip_light_time_sec = round_trip_sec,
                ),
            )
            rx = TelemetryCore.read_table(joinpath(run_dir, "events_rx.csv"))
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
                TelemetryCore.run_directory(gap_id);
                batch_size = 3,
                generation_gaps = [gap],
                hole_feed = TelemetryCore.HoleFeed(
                    gap_dir,
                    Emitter.instrument_epoch(start, 0.01),
                    4.0,
                    720,
                ),
            )
        end
        tx = TelemetryCore.read_table(joinpath(gap_dir, "events_tx.csv"))
        gap_rows = tx[tx.Batch .== "SCHEDULED", :]
        @test String.(gap_rows.Event) == ["gap_start", "gap_end"]
        # Segments at −14.4, −13.4, −12.4 min form batch 1; −11.4 and −10.4
        # are pending when −9.4 falls inside the gap and are discarded.
        # Recording resumes on the segment grid, at −5.4 min.
        @test DateTime(gap_rows.SimTime[1]) == start - Minute(11) - Second(24)
        @test DateTime(gap_rows.SimTime[2]) == start - Minute(5) - Second(24)
        @test TelemetryCore.max_logged_batch_id(gap_dir) == 3
        @test TelemetryCore.batch_content_epochs(gap_dir)["ARCH_batch_2"] ==
              start - Minute(5) - Second(24)
        # A scheduled gap inside the blind spot is declared at the mission epoch.
        holes = TelemetryCore.read_hole_feed(gap_dir)
        @test nrow(holes) == 1 && holes.Cause[1] == "scheduled" && ismissing(holes.Batch[1])
        @test holes.DeclaredAt[1] == start
        @test holes.ContentStart[1] == DateTime(gap_rows.SimTime[1]) &&
              holes.ContentEnd[1] == DateTime(gap_rows.SimTime[2])
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
                TelemetryCore.run_directory(rec_id);
                batch_size = 3,
                onboard_capacity_batches = 2,
                hole_feed = TelemetryCore.HoleFeed(
                    rec_dir,
                    Emitter.instrument_epoch(start, 0.01),
                    4.0,
                    720,
                ),
            )
        end
        @test TelemetryCore.max_logged_batch_id(rec_dir) == 2
        tx = TelemetryCore.read_table(joinpath(rec_dir, "events_tx.csv"))
        rec_rows = tx[tx.Batch .== "RECORDER", :]
        @test String.(rec_rows.Event) == ["gap_start"]
        @test DateTime(rec_rows.SimTime[1]) == start - Minute(8) - Second(24)
        @test TelemetryCore.open_recorder_gap(rec_dir)
        # An open recorder gap is not yet a declared hole.
        @test !isfile(joinpath(rec_dir, "holes.csv"))
        @test TelemetryCore.open_recorder_gap_start(rec_dir) ==
              start - Minute(8) - Second(24)
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
        clock = TelemetryCore.TickClock(start, start + Second(3 * 1800))
        drive_components(
            clock;
            emitter = c -> Emitter.run_emitter(
                c,
                link,
                TelemetryCore.run_directory(live_id),
                VirtualInstrument.InstrumentState(
                    TelemetryCore.get_current_sim_time(c),
                    4.0,
                    60.0,
                    "synthetic",
                    "",
                );
                batch_size = 3,
                onboard_capacity_batches = 2,
            ),
        )
        @test TelemetryCore.max_logged_batch_id(live_dir) == 2
        tx = TelemetryCore.read_table(joinpath(live_dir, "events_tx.csv"))
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

@testset "External payload on the grid (scheduled gaps, recorder overflow)" begin
    # Geometry of the consumer report: 0.2 Hz, 50 s segments of 10 samples,
    # 10 segments per batch; ramp payload, row r holding r.
    fs = 0.2
    span = Second(500)
    start = DateTime(2035, 3, 7)
    origin = Emitter.instrument_epoch(start, 0.1) # start − 8640 s
    stub = Dict{String,Any}(
        "simulation" => Dict{String,Any}(
            "speed_up" => 3600.0,
            "start_sim_time" => "2035-03-07T00:00:00",
        ),
    )
    mktempdir() do tmp
        ramp = joinpath(tmp, "ramp.csv")
        CSV.write(ramp, DataFrame(Amplitude = Float32.(1:40_000)))

        # Scheduled gaps in the blind spot and in the mission phase, both
        # ending off the segment grid; the second ends on the sample grid,
        # as a gap scheduled on whole minutes does.
        gap_id = "TEST_RUN_grid_gap_pid$(getpid())"
        gap_dir = TelemetryCore.setup_run_dir(gap_id; cfg = stub)
        try
            gaps = [
                (start - Minute(90), start - Minute(58) + Second(3)),
                (start + Minute(15), start + Minute(25)),
            ]
            vi, pending = with_logger(NullLogger()) do
                Emitter.pre_populate(
                    VirtualInstrument.InstrumentState(origin, fs, 50.0, "external", ramp),
                    start,
                    TelemetryCore.run_directory(gap_id);
                    batch_size = 10,
                    generation_gaps = gaps,
                )
            end
            # The pre-population alone: every ARCH batch and the partial
            # batch on the payload grid.
            blind = ramp_alignment(gap_dir, origin, fs)
            @test blind.checked == 12
            @test isempty(blind.misaligned) && isempty(blind.repeated)
            @test all(
                s -> s.data[1] == round(Int, (s.timestamp - origin).value / 1000 * fs) + 1,
                pending,
            )
            link = ChannelEffects.LinkModel(
                TelemetryCore.VisibilityModel(Time(0), Second(24 * 3600), "flat"),
            )
            clock = TelemetryCore.TickClock(start, start + Second(3 * 3600))
            drive_components(
                clock;
                emitter = c -> Emitter.run_emitter(
                    c,
                    link,
                    TelemetryCore.run_directory(gap_id),
                    vi;
                    batch_size = 10,
                    pending_segments = pending,
                    generation_gaps = gaps,
                ),
            )
            tx = TelemetryCore.read_table(joinpath(gap_dir, "events_tx.csv"))
            scheduled = tx[tx.Batch .== "SCHEDULED", :]
            @test String.(scheduled.Event) ==
                  ["gap_start", "gap_end", "gap_start", "gap_end"]
            bounds = DateTime.(scheduled.SimTime)
            # Recording resumes at the first segment boundary after each gap.
            @test bounds[2] == origin + Second(5200) && bounds[4] == origin + Second(10_150)
            # [gap_start, gap_end) is exactly the content not recorded: a
            # batch closes at each gap start, the next opens at the gap end.
            epochs = collect(values(TelemetryCore.batch_content_epochs(gap_dir)))
            for (g0, g1) in ((bounds[1], bounds[2]), (bounds[3], bounds[4]))
                @test g0 - span in epochs && g1 in epochs
                @test !any(e -> e + span > g0 && e < g1, epochs)
            end
            alignment = ramp_alignment(gap_dir, origin, fs)
            @test alignment.checked == count(==("gen"), tx.Event)
            @test isempty(alignment.misaligned) && isempty(alignment.repeated)
        finally
            rm(gap_dir; recursive = true, force = true)
        end

        # Recorder overflow: the link is down for the first 30 min, two
        # batches fit, and discarded batches are generated normally, so the
        # stream stays on the grid when recording resumes.
        rec_id = "TEST_RUN_grid_recorder_pid$(getpid())"
        rec_dir = TelemetryCore.setup_run_dir(rec_id; cfg = stub)
        try
            link = ChannelEffects.LinkModel(
                TelemetryCore.VisibilityModel(Time(0, 30), Second(23 * 3600), "flat"),
            )
            clock = TelemetryCore.TickClock(start, start + Second(3 * 3600))
            drive_components(
                clock;
                emitter = c -> Emitter.run_emitter(
                    c,
                    link,
                    TelemetryCore.run_directory(rec_id),
                    VirtualInstrument.InstrumentState(start, fs, 50.0, "external", ramp);
                    batch_size = 10,
                    onboard_capacity_batches = 2,
                    hole_feed = TelemetryCore.HoleFeed(rec_dir, start, fs, 100),
                ),
            )
            tx = TelemetryCore.read_table(joinpath(rec_dir, "events_tx.csv"))
            recorder = tx[tx.Batch .== "RECORDER", :]
            # The gap closes when the link opens and the two buffered batches
            # leave, after an overflow that began while the link was down.
            @test "gap_end" in String.(recorder.Event)
            # The closed recorder gap is declared once, at or after its content end.
            opened = DateTime(recorder.SimTime[findfirst(==("gap_start"), recorder.Event)])
            closed = DateTime(recorder.SimTime[findfirst(==("gap_end"), recorder.Event)])
            holes = TelemetryCore.read_hole_feed(rec_dir)
            rec_hole = holes[holes.Cause .== "recorder", :]
            @test nrow(rec_hole) == 1
            @test rec_hole.ContentStart[1] == opened && rec_hole.ContentEnd[1] == closed
            @test rec_hole.DeclaredAt[1] >= rec_hole.ContentEnd[1]
            alignment = ramp_alignment(rec_dir, start, fs)
            @test alignment.checked == count(==("gen"), tx.Event) > 2
            @test isempty(alignment.misaligned) && isempty(alignment.repeated)
        finally
            rm(rec_dir; recursive = true, force = true)
        end
    end
end

@testset "Downlink served during a scheduled generation gap" begin
    # A one-hour gap opening 20 min into a contact, with a backlog of
    # seventeen archive batches, two in-flight slots, and 5 min per transfer:
    # the backlog keeps flowing to the ground while nothing is generated.
    start = DateTime(2035, 3, 7)
    inflight = 2
    gap = (start + Minute(20), start + Minute(80))
    run_id = "TEST_RUN_gap_downlink_pid$(getpid())"
    run_dir = TelemetryCore.setup_run_dir(
        run_id;
        cfg = Dict{String,Any}(
            "simulation" => Dict{String,Any}(
                "speed_up" => 3600.0,
                "start_sim_time" => "2035-03-07T00:00:00",
            ),
        ),
    )
    try
        vi, pending = with_logger(NullLogger()) do
            Emitter.pre_populate(
                VirtualInstrument.InstrumentState(
                    Emitter.instrument_epoch(start, 0.1),
                    0.2,
                    50.0,
                    "synthetic",
                    "",
                ),
                start,
                TelemetryCore.run_directory(run_id);
                batch_size = 10,
                generation_gaps = [gap],
            )
        end
        link = ChannelEffects.LinkModel(
            TelemetryCore.VisibilityModel(Time(0), Second(24 * 3600), "flat"),
        )
        clock = TelemetryCore.TickClock(start, start + Millisecond(2500 * 3600))
        drive_components(
            clock;
            emitter = c -> Emitter.run_emitter(
                c,
                link,
                TelemetryCore.run_directory(run_id),
                vi;
                batch_size = 10,
                pending_segments = pending,
                generation_gaps = [gap],
                max_inflight_batches = inflight,
            ),
            receiver = c -> Receiver.run_receiver(
                c,
                link,
                TelemetryCore.run_directory(run_id);
                orig_stdout = devnull,
                batch_transfer_sec = 300.0,
            ),
        )
        tx = TelemetryCore.read_table(joinpath(run_dir, "events_tx.csv"))
        rx_events = TelemetryCore.read_table(joinpath(run_dir, "events_rx.csv"))
        inside(t) = gap[1] + Minute(2) < DateTime(t) < gap[2]
        @test count(==("SCHEDULED"), tx.Batch) == 2
        # The defect left the link idle through the gap: no batch was placed
        # on it, and at most the `inflight` batches already there reached the
        # ground. More than that is the downlink being served. The full
        # rate, about eleven transfers in the window, is not asserted.
        @test count(r -> r.Event == "tx" && inside(r.SimTime), eachrow(tx)) > inflight
        @test count(r -> r.Event == "ingested" && inside(r.SimTime), eachrow(rx_events)) >
              inflight
    finally
        rm(run_dir; recursive = true, force = true)
    end
end
