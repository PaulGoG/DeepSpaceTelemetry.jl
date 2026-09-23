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
    events(dir) = CSV.read(joinpath(dir, "component_events.csv"), DataFrame)
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
            @test !isfile(joinpath(run_dir, "component_events.csv"))
            tx = CSV.read(joinpath(run_dir, "events_tx.csv"), DataFrame)
            @test count(==("gen"), tx.Event) > 5
            @test isfile(joinpath(run_dir, "alert_latency.csv"))
            @test isfile(joinpath(run_dir, "plots", "alert_latency.png"))
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
        rx = CSV.read(joinpath(run_dir, "events_rx.csv"), DataFrame)
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
