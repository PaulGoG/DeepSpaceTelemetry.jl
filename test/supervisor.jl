# Supervisor: file loggers, supervision policies, the headless mission, the scenario library.

@testset "CleanFileLogger" begin
    mktempdir() do tmp
        path = joinpath(tmp, "component.log")
        with_logger(Supervisor.CleanFileLogger(path, 10_000)) do
            @info "\e[32mcolored\e[0m message"
            @warn "trouble" exception = (ErrorException("boom"), backtrace())
        end
        lines = readlines(path)
        @test lines[1] == "[Info] colored message"
        @test lines[2] == "[Warn] trouble"
        @test occursin("exception = boom", lines[3])
        # Rotation: a file beyond the cap is moved aside before the next record.
        with_logger(Supervisor.CleanFileLogger(path, 10)) do
            @info "after rotation"
        end
        @test readlines(path) == ["[Info] after rotation"]
        @test count(f -> startswith(f, "component"), readdir(tmp)) == 2
    end
end

@testset "Supervisor log tee" begin
    mktempdir() do dir
        with_logger(NullLogger()) do
            Supervisor.with_supervisor_log(dir, 10_000) do
                @error "[POST] forced post-processing failure"
                @info "[SUPERVISOR] record"
            end
        end
        text = read(joinpath(dir, "supervisor.log"), String)
        @test occursin("forced post-processing failure", text)
        @test occursin("[SUPERVISOR] record", text)
    end
end

@testset "Supervisor policies (synthetic components)" begin
    policy(p; restarts = 2, watchdog = 0.3) =
        (on_component_failure = p, max_restarts = restarts, watchdog_sec = watchdog)
    clock = TelemetryCore.SimulationClock(now(), DateTime(2035), 1.0)
    events(dir) = TelemetryCore.read_table(joinpath(dir, "component_events.csv"))
    # The [SUPERVISOR] failure and policy records go to the active logger.
    with_logger(NullLogger()) do
        mktempdir() do tmp
            # abort: a failure raises the stop flag and the partner stops.
            dir = mkpath(joinpath(tmp, "abort"))
            stop = Threads.Atomic{Bool}(false)
            heartbeats = Dict{Symbol,String}(
                :a => joinpath(dir, "a_alive"),
                :b => joinpath(dir, "b_alive"),
            )
            spawners = Dict{Symbol,Function}(
                :a => attempt -> Threads.@spawn(begin
                    sleep(0.2)
                    error("component a failed")
                end),
                :b => attempt -> Threads.@spawn(begin
                    while !stop[]
                        sleep(0.02)
                    end
                    :stopped
                end),
            )
            t0 = time()
            counts = Supervisor.supervise!(
                spawners,
                dir,
                clock,
                stop,
                heartbeats,
                policy("abort");
                poll_sec = 0.05,
            )
            @test stop[] && time() - t0 < 5.0
            @test counts == Dict(:a => 0, :b => 0)
            ev = events(dir)
            @test any((ev.Component .== "a") .& (ev.Event .== "down"))

            # restart: the failed component is relaunched after the hook ran.
            dir = mkpath(joinpath(tmp, "restart"))
            stop = Threads.Atomic{Bool}(false)
            hook_calls = Tuple{Symbol,Int}[]
            spawners = Dict{Symbol,Function}(
                :a =>
                    attempt -> Threads.@spawn(
                        attempt == 0 ? error("first launch fails") : sleep(0.05)
                    ),
                :b => attempt -> Threads.@spawn(sleep(0.05)),
            )
            counts = Supervisor.supervise!(
                spawners,
                dir,
                clock,
                stop,
                heartbeats,
                policy("restart");
                poll_sec = 0.05,
                on_restart = (name, attempt) -> push!(hook_calls, (name, attempt)),
            )
            @test counts[:a] == 1 && counts[:b] == 0 && !stop[]
            @test hook_calls == [(:a, 1)]
            ev = events(dir)
            @test [String(e) for e in ev[ev.Component .== "a", :Event]] == ["down", "restart"]

            # continue: the partner keeps running one-sided.
            dir = mkpath(joinpath(tmp, "continue"))
            stop = Threads.Atomic{Bool}(false)
            spawners = Dict{Symbol,Function}(
                :a => attempt -> Threads.@spawn(error("down for good")),
                :b => attempt -> Threads.@spawn(sleep(0.4)),
            )
            counts = Supervisor.supervise!(
                spawners,
                dir,
                clock,
                stop,
                heartbeats,
                policy("continue");
                poll_sec = 0.05,
            )
            @test !stop[] && counts[:a] == 0
            ev = events(dir)
            @test all(==("down"), ev.Event) && nrow(ev) == 1

            # watchdog: a silent heartbeat is recorded as stalled, then recovered.
            dir = mkpath(joinpath(tmp, "watchdog"))
            stop = Threads.Atomic{Bool}(false)
            spawners = Dict{Symbol,Function}(
                :a => attempt -> Threads.@spawn(begin
                    touch(heartbeats[:a])
                    sleep(1.0) # silent for longer than the watchdog threshold
                    touch(heartbeats[:a])
                    sleep(0.2) # heartbeat fresh again, observed by at least one poll
                    rm(heartbeats[:a]; force = true)
                end),
                :b => attempt -> Threads.@spawn(sleep(0.05)),
            )
            Supervisor.supervise!(
                spawners,
                dir,
                clock,
                stop,
                heartbeats,
                policy("abort"; watchdog = 0.3);
                poll_sec = 0.05,
            )
            ev = events(dir)
            @test [String(e) for e in ev[ev.Component .== "a", :Event]] == ["stalled", "recovered"]
        end
    end
end

@testset "Headless mission through Supervisor.run_mission" begin
    mktempdir() do tmp
        ext_path = joinpath(tmp, "ext.csv")
        CSV.write(ext_path, DataFrame(Amplitude = Float32.(1:200_000)))
        cfg = valid_test_cfg()
        cfg["simulation"]["mission_wall_seconds"] = 4.0
        cfg["simulation"]["speed_up"] = 1800.0
        cfg["simulation"]["initial_downtime_days"] = 0.01
        cfg["physics"]["data_source"] = "external"
        cfg["physics"]["external_data_path"] = ext_path
        cfg["physics"]["batch_size"] = 3
        cfg["telemetry"]["session_start"] = "00:00:00"
        cfg["telemetry"]["session_duration_hours"] = 24.0
        cfg["telemetry"]["bandwidth_profile"] = "flat"
        cfg["telemetry"]["max_batches_per_hour"] = 1800.0
        cfg["post_processing"] = Dict{String,Any}(
            "generate_mask_timeline" => true,
            "expand_to_pointwise_masks" => true,
            "target_event_rows" => [-1],
        )
        # A scheduled generation gap 06:28:48–06:43:48, ending off the
        # segment grid of the payload origin 05:45:36.
        cfg["disruption"] = Dict{String,Any}(
            "events" => Any[Dict{String,Any}(
                "type" => "maintenance",
                "affects" => "generation",
                "start_day" => 0.02,
                "duration_hours" => 0.25,
            ),],
        )
        run_id = "TEST_RUN_mission_pid$(getpid())"
        # mission_plan leaves the caller's configuration untouched: the
        # provenance stamp lands on the plan's own copy.
        original = deepcopy(cfg)
        plan = with_logger(NullLogger()) do
            Supervisor.mission_plan(cfg; run_id = run_id)
        end
        @test cfg == original && !haskey(cfg, "provenance")
        @test haskey(plan.cfg, "provenance") && plan.cfg !== cfg
        run_dir = with_logger(NullLogger()) do
            Supervisor.run_mission(cfg; run_id = run_id, orig_stdout = devnull)
        end
        try
            @test run_dir == TelemetryCore.run_directory(run_id)
            @test isfile(joinpath(run_dir, "RUN_COMPLETE"))
            @test !isfile(joinpath(run_dir, "RUN_ACTIVE")) &&
                  !isfile(joinpath(run_dir, "RUN_ABORTED"))
            @test isfile(joinpath(run_dir, "clock_anchor.toml"))
            @test isfile(joinpath(run_dir, "mission_profile.csv"))
            @test isfile(joinpath(run_dir, "masks", "telemetry_mask_timeline.csv"))
            @test isfile(joinpath(run_dir, "masks", "pointwise_mask_final.csv"))
            @test filesize(joinpath(run_dir, "emitter.log")) > 0
            @test filesize(joinpath(run_dir, "receiver.log")) > 0
            @test occursin("[POST]", read(joinpath(run_dir, "supervisor.log"), String))
            snapshot = TOML.parsefile(joinpath(run_dir, "config_snapshot.toml"))
            @test haskey(snapshot["provenance"], "external_data_sha256")
            @test snapshot["provenance"]["external_data_rows"] == 200_000
            origin = DateTime(snapshot["provenance"]["payload_origin"])
            @test origin == DateTime(2035, 1, 1, 5, 45, 36) == plan.payload_origin
            @test !isfile(joinpath(run_dir, "component_events.csv"))
            tx = TelemetryCore.read_table(joinpath(run_dir, "events_tx.csv"))
            @test count(==("gen"), tx.Event) > 5
            scheduled = tx[tx.Batch .== "SCHEDULED", :]
            @test String.(scheduled.Event) == ["gap_start", "gap_end"]
            @test DateTime(scheduled.SimTime[2]) == DateTime(2035, 1, 1, 6, 44, 36)
            alignment = ramp_alignment(run_dir, origin, 4.0)
            @test alignment.checked == count(==("gen"), tx.Event)
            @test isempty(alignment.misaligned) && isempty(alignment.repeated)
            @test isfile(joinpath(run_dir, "alert_latency.csv"))
            @test isfile(joinpath(run_dir, "plots", "alert_latency.png"))
            # A stranded run: the sentinels of a supervisor killed during
            # post-processing, with a product missing. complete_run
            # recomputes the products and settles the sentinels.
            @test !isfile(joinpath(run_dir, "RUN_POSTPROCESSING"))
            function strand!(marker::Bool)
                rm(joinpath(run_dir, "RUN_COMPLETE"); force = true)
                rm(joinpath(run_dir, "RUN_ABORTED"); force = true)
                touch(joinpath(run_dir, "RUN_ACTIVE"))
                rm(joinpath(run_dir, "RUN_POSTPROCESSING"); force = true)
                marker && touch(joinpath(run_dir, "RUN_POSTPROCESSING"))
                rm(joinpath(run_dir, "delivery_delay.csv"); force = true)
                return nothing
            end
            complete(force::Bool) = with_logger(NullLogger()) do
                Supervisor.complete_run(run_id; force = force, orig_stdout = devnull)
            end
            @test_throws ArgumentError complete(true)   # settled, not stranded
            strand!(true)
            @test_throws ArgumentError complete(false)  # written to a moment ago
            @test complete(true) == run_dir
            @test isfile(joinpath(run_dir, "RUN_COMPLETE")) &&
                  !isfile(joinpath(run_dir, "RUN_ACTIVE")) &&
                  !isfile(joinpath(run_dir, "RUN_POSTPROCESSING"))
            @test isfile(joinpath(run_dir, "delivery_delay.csv"))
            @test occursin(
                "Completing a stranded run",
                read(joinpath(run_dir, "supervisor.log"), String),
            )
            # Without the sentinel, as in a run of an earlier version, the
            # verdict comes from the record: the profile reaches the deadline.
            strand!(false)
            complete(true)
            @test isfile(joinpath(run_dir, "RUN_COMPLETE"))
            # A profile that stops well before the deadline is a mission that
            # did not end: the products are computed, the run is aborted.
            strand!(false)
            profile = joinpath(run_dir, "mission_profile.csv")
            rows = readlines(profile)
            write(profile, join(rows[1:max(2, length(rows)÷4)], "\n") * "\n")
            complete(true)
            @test isfile(joinpath(run_dir, "RUN_ABORTED")) &&
                  !isfile(joinpath(run_dir, "RUN_ACTIVE")) &&
                  !isfile(joinpath(run_dir, "RUN_COMPLETE"))
        finally
            rm(run_dir; recursive = true, force = true)
        end
    end
end

@testset "Emitter restart through the supervisor (external payload)" begin
    # The production restart path: the first emitter fails after 2 s, the
    # supervisor records the STREAM gap and spawns a replacement with the
    # payload origin of the first start. Geometry of the consumer report
    # (0.2 Hz, 50 s segments, 10 per batch), ramp payload.
    mktempdir() do tmp
        ramp = joinpath(tmp, "ramp.csv")
        CSV.write(ramp, DataFrame(Amplitude = Float32.(1:100_000)))
        cfg = valid_test_cfg()
        cfg["simulation"]["speed_up"] = 3600.0
        cfg["simulation"]["mission_wall_seconds"] = 5.0
        cfg["simulation"]["initial_downtime_days"] = 0.05
        cfg["simulation"]["start_sim_time"] = "2035-03-07T00:00:00"
        cfg["physics"] = Dict{String,Any}(
            "data_source" => "external",
            "external_data_path" => ramp,
            "sample_rate" => 0.2,
            "segment_duration_sec" => 50.0,
            "batch_size" => 10,
        )
        cfg["telemetry"]["session_start"] = "00:00:00"
        cfg["telemetry"]["session_duration_hours"] = 24.0
        cfg["telemetry"]["bandwidth_profile"] = "flat"
        cfg["telemetry"]["max_batches_per_hour"] = 1800.0
        cfg["supervision"] =
            Dict{String,Any}("on_component_failure" => "restart", "max_restarts" => 1)
        plan = with_logger(NullLogger()) do
            Supervisor.mission_plan(cfg; run_id = "TEST_RUN_restart_pid$(getpid())")
        end
        run_dir = TelemetryCore.setup_run_dir(plan.run_id; cfg = plan.cfg)
        try
            instrument, pending = with_logger(NullLogger()) do
                Emitter.pre_populate(
                    Supervisor.build_instrument(
                        plan.physics,
                        plan.payload_origin,
                        plan.markers,
                    ),
                    plan.start_sim,
                    plan.run_id;
                    batch_size = plan.physics.batch_size,
                )
            end
            clock = TelemetryCore.SimulationClock(now(), plan.start_sim, plan.speed_up)
            stop_flag = Threads.Atomic{Bool}(false)
            heartbeats = Dict{Symbol,String}(
                :emitter => joinpath(run_dir, "emitter_alive"),
                :receiver => joinpath(run_dir, "receiver_alive"),
            )
            loggers = (
                Supervisor.CleanFileLogger(joinpath(run_dir, "emitter.log"), 10^8),
                Supervisor.CleanFileLogger(joinpath(run_dir, "receiver.log"), 10^8),
            )
            spawners_until(deadline) = Supervisor.component_spawners(
                plan,
                run_dir,
                clock,
                deadline,
                stop_flag,
                heartbeats,
                instrument,
                pending,
                loggers...,
                devnull,
            )
            first_launch = spawners_until(now() + Second(2))
            launches = spawners_until(now() + Second(5))
            spawners = Dict{Symbol,Function}(
                :emitter =>
                    attempt ->
                        attempt == 0 ?
                        Threads.@spawn(begin
                            wait(first_launch[:emitter](0))
                            error("injected emitter fault")
                        end) : launches[:emitter](attempt),
                :receiver => launches[:receiver],
            )
            restarts = with_logger(NullLogger()) do
                Supervisor.supervise!(
                    spawners,
                    run_dir,
                    clock,
                    stop_flag,
                    heartbeats,
                    plan.supervision,
                )
            end
            @test restarts == Dict(:emitter => 1, :receiver => 0)
            components = TelemetryCore.read_table(joinpath(run_dir, "component_events.csv"))
            @test String.(components[components.Component .== "emitter", :Event]) ==
                  ["down", "restart"]

            # A consumer's view: the origin from the snapshot, the gap from
            # the event log, the payload from the batches.
            snapshot = TOML.parsefile(joinpath(run_dir, "config_snapshot.toml"))
            origin = DateTime(snapshot["provenance"]["payload_origin"])
            @test origin == plan.start_sim - Minute(72)
            tx = TelemetryCore.read_table(joinpath(run_dir, "events_tx.csv"))
            stream = tx[tx.Batch .== "STREAM", :]
            @test String.(stream.Event) == ["gap_start", "gap_end"]
            resume = DateTime(stream.SimTime[2])
            @test (resume - origin).value % 50_000 == 0
            epochs = collect(values(TelemetryCore.batch_content_epochs(run_dir)))
            @test resume in epochs # the replacement's first batch opens at the gap end
            @test !isempty(readdir(joinpath(run_dir, "ground")))
            alignment = ramp_alignment(run_dir, origin, 0.2)
            @test alignment.checked == count(==("gen"), tx.Event)
            @test isempty(alignment.misaligned) && isempty(alignment.repeated)
        finally
            rm(run_dir; recursive = true, force = true)
        end
    end
end

@testset "Scenario library" begin
    scenario_dir = joinpath(TelemetryCore.PROJECT_ROOT, "scenarios")
    files = sort(filter(f -> endswith(f, ".toml"), readdir(scenario_dir)))
    @test length(files) >= 11
    @test "smoke_1d.toml" in files && "recovery_12h_seasonal.toml" in files
    mktempdir() do tmp
        ext_path = joinpath(tmp, "ext.csv")
        CSV.write(ext_path, DataFrame(Amplitude = Float32.(1:10_000)))
        for f in files
            cfg = TelemetryCore.load_config(joinpath(scenario_dir, f))
            if cfg["physics"]["data_source"] == "external"
                cfg["physics"]["external_data_path"] = ext_path
            end
            validated = with_logger(NullLogger()) do
                TelemetryCore.validate_config(cfg)
            end
            @test validated isa AbstractDict
        end
    end
    # The root configuration is the reference scenario, section by section.
    root = TelemetryCore.load_config(joinpath(TelemetryCore.PROJECT_ROOT, "config.toml"))
    ref = TelemetryCore.load_config(joinpath(scenario_dir, "recovery_12h_seasonal.toml"))
    for section in (
        "simulation",
        "storage",
        "telemetry",
        "contacts",
        "ground",
        "events",
        "physics",
        "packet_loss",
        "disruption",
        "post_processing",
    )
        @test get(root, section, nothing) == get(ref, section, nothing)
    end
    # The smoke scenario runs end to end as shipped.
    cfg = TelemetryCore.load_config(joinpath(scenario_dir, "smoke_1d.toml"))
    run_id = "TEST_RUN_smoke_pid$(getpid())"
    run_dir = with_logger(NullLogger()) do
        Supervisor.run_mission(cfg; run_id = run_id, orig_stdout = devnull)
    end
    try
        @test isfile(joinpath(run_dir, "RUN_COMPLETE"))
        @test isfile(joinpath(run_dir, "delivery_delay.csv"))
        @test isfile(joinpath(run_dir, "plots", "mission_summary_global.png"))
        rx = TelemetryCore.read_table(joinpath(run_dir, "events_rx.csv"))
        # How many batches the scenario delivers within its 12 s wall-clock
        # budget depends on the host keeping pace with the accelerated clock,
        # so the floor only separates a pipeline that moved data from one that
        # stalled; the per-segment cost that sets the rate is measured by the
        # physics/next_segment and io/batch_save_load benchmarks.
        @test count(==("ingested"), rx.Event) > 10
    finally
        rm(run_dir; recursive = true, force = true)
    end
end
