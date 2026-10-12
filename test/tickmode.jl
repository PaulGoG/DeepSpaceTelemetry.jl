# The tick clock: configuration of the two modes, the anchor, the
# cooperative scheduler, and the determinism claim — the same seed twice
# gives the same event logs and mask timeline to the byte, another seed
# does not, and the production count follows from the span alone.

@testset "Simulation mode configuration" begin
    tick = TelemetryCore.load_config(
        joinpath(TelemetryCore.PROJECT_ROOT, "scenarios", "deterministic_1d.toml"),
    )
    @test TelemetryCore.simulation_mode(tick) == "tick"
    @test TelemetryCore.mission_span_days(tick) == 1.0
    @test TelemetryCore.simulation_mode(Dict{String,Any}()) == "wall"
    wall = TelemetryCore.load_config(
        joinpath(TelemetryCore.PROJECT_ROOT, "scenarios", "smoke_1d.toml"),
    )
    @test TelemetryCore.mission_span_days(wall) ≈ 12.0 * 3600.0 / 86_400.0
    # A key of the other mode is an error naming the mode, never ignored.
    bad = deepcopy(tick)
    bad["simulation"]["speed_up"] = 3600.0
    @test_throws ArgumentError TelemetryCore.validate_config(bad)
    bad = deepcopy(tick)
    bad["simulation"]["mission_wall_seconds"] = 12.0
    @test_throws ArgumentError TelemetryCore.validate_config(bad)
    bad = deepcopy(tick)
    delete!(bad["simulation"], "mission_days")
    @test_throws ArgumentError TelemetryCore.validate_config(bad)
    bad = deepcopy(tick)
    bad["simulation"]["mission_days"] = 0.0
    @test_throws ArgumentError TelemetryCore.mission_days_setting(bad)
    bad = deepcopy(tick)
    bad["simulation"]["mode"] = "logical"
    @test_throws ArgumentError TelemetryCore.simulation_mode(bad)
    bad = deepcopy(tick)
    bad["dashboard"]["receiver_status_panel"] = true
    @test_throws ArgumentError TelemetryCore.validate_config(bad)
    bad = deepcopy(wall)
    bad["simulation"]["mission_days"] = 1.0
    @test_throws ArgumentError TelemetryCore.validate_config(bad)
    # The storage estimate sizes a tick mission from its span.
    est = TelemetryCore.estimate_artifacts(tick)
    @test est.mission_days == 1
    # A wall scenario converts to tick mode with its span intact and
    # validates; a tick configuration passes through unchanged.
    converted = TelemetryCore.tick_configuration(wall)
    @test converted["simulation"]["mode"] == "tick"
    @test converted["simulation"]["mission_days"] ≈ TelemetryCore.mission_span_days(wall)
    @test !haskey(converted["simulation"], "speed_up") &&
          !haskey(converted["simulation"], "mission_wall_seconds")
    @test wall["simulation"]["speed_up"] == 3600.0   # the source is untouched
    @test with_logger(NullLogger()) do
        TelemetryCore.validate_config(converted)
    end isa AbstractDict
    @test TelemetryCore.tick_configuration(tick) == tick
end

@testset "Tick clock anchor and scheduler" begin
    epoch = DateTime(2035, 1, 1, 6)
    @test_throws ArgumentError TelemetryCore.TickClock(epoch, epoch)
    mktempdir() do tmp
        clock = TelemetryCore.TickClock(epoch, epoch + Day(1))
        TelemetryCore.save_clock_anchor(tmp, clock)
        restored = TelemetryCore.load_clock_anchor(tmp)
        @test restored.mode == "tick" && restored.deadline === nothing
        @test restored.horizon == epoch + Day(1)
        @test restored.clock isa TelemetryCore.TickClock &&
              restored.clock.start_sim_time == epoch
    end
    # Two tasks interleave by instant, then by priority, then by
    # registration; a wakeup beyond the horizon resumes at the horizon.
    clock = TelemetryCore.TickClock(epoch, epoch + Hour(1))
    trace = Tuple{Symbol,DateTime}[]
    body(name, waits) =
        () -> begin
            for w in waits
                push!(trace, (name, clock.now_sim))
                TelemetryCore.wait_until!(
                    clock,
                    epoch + w;
                    priority = name === :emitter ? TelemetryCore.EMITTER_PRIORITY :
                               TelemetryCore.RECEIVER_PRIORITY,
                )
            end
            push!(trace, (name, clock.now_sim))
        end
    tasks = Dict{Symbol,Task}(
        :receiver => TelemetryCore.tick_spawn(
            clock,
            TelemetryCore.RECEIVER_PRIORITY,
            body(:receiver, (Minute(10), Minute(20), Hour(3))),
        ),
        :emitter => TelemetryCore.tick_spawn(
            clock,
            TelemetryCore.EMITTER_PRIORITY,
            body(:emitter, (Minute(10), Minute(30))),
        ),
    )
    TelemetryCore.run_ticks!(clock, tasks)
    @test all(istaskdone, values(tasks)) && !any(istaskfailed, values(tasks))
    @test trace == [
        (:emitter, epoch),
        (:receiver, epoch),
        (:emitter, epoch + Minute(10)),
        (:receiver, epoch + Minute(10)),
        (:receiver, epoch + Minute(20)),
        (:emitter, epoch + Minute(30)),
        (:receiver, epoch + Hour(1)),
    ]
    @test TelemetryCore.horizon_reached(clock)
    # The idle wait resumes after the next wakeup of another task.
    clock = TelemetryCore.TickClock(epoch, epoch + Hour(1))
    seen = DateTime[]
    tasks = Dict{Symbol,Task}(
        :emitter => TelemetryCore.tick_spawn(
            clock,
            TelemetryCore.EMITTER_PRIORITY,
            () -> TelemetryCore.wait_until!(clock, epoch + Minute(15)),
        ),
        :receiver => TelemetryCore.tick_spawn(
            clock,
            TelemetryCore.RECEIVER_PRIORITY,
            () -> begin
                TelemetryCore.wait_for_change!(clock)
                push!(seen, clock.now_sim)
                TelemetryCore.wait_until_or_change!(clock, epoch + Minute(45))
                push!(seen, clock.now_sim)
            end,
        ),
    )
    TelemetryCore.run_ticks!(clock, tasks)
    @test seen == [epoch + Minute(15), epoch + Minute(45)]
    # A failing task is handed to the callback once; a replacement takes
    # its name.
    clock = TelemetryCore.TickClock(epoch, epoch + Hour(1))
    failures = Symbol[]
    tasks = Dict{Symbol,Task}(
        :emitter => TelemetryCore.tick_spawn(
            clock,
            TelemetryCore.EMITTER_PRIORITY,
            () -> error("component fault"),
        ),
    )
    TelemetryCore.run_ticks!(
        clock,
        tasks;
        on_task_failed = (name, task) -> begin
            push!(failures, name)
            length(failures) == 1 ?
            TelemetryCore.tick_spawn(
                clock,
                TelemetryCore.EMITTER_PRIORITY,
                () -> TelemetryCore.wait_until!(clock, epoch + Minute(5)),
            ) : nothing
        end,
    )
    @test failures == [:emitter] && !istaskfailed(tasks[:emitter])
end

@testset "Deterministic tick missions" begin
    cfg = TelemetryCore.load_config(
        joinpath(TelemetryCore.PROJECT_ROOT, "scenarios", "deterministic_1d.toml"),
    )
    cfg["simulation"]["mission_days"] = 0.25
    cfg["simulation"]["initial_downtime_days"] = 0.1
    cfg["packet_loss"]["p_loss"] = 0.2
    cfg["post_processing"]["session_figures"] = false
    cfg["post_processing"]["state_raster"] = false
    cfg["post_processing"]["alert_latency"] = false
    cfg["post_processing"]["delivery_delay"] = false
    products(run_dir) = (
        read(joinpath(run_dir, "events_tx.csv")),
        read(joinpath(run_dir, "events_rx.csv")),
        read(joinpath(run_dir, "masks", "telemetry_mask_timeline.csv")),
        read(joinpath(run_dir, "masks", "batch_epochs.csv")),
    )
    function tick_run(label, seed)
        c = deepcopy(cfg)
        c["simulation"]["rng_seed"] = seed
        run_id = "TEST_RUN_tick_$(label)_pid$(getpid())"
        run_dir = with_logger(NullLogger()) do
            Supervisor.run_mission(c; run_id = run_id, orig_stdout = devnull)
        end
        return run_dir
    end
    runs = String[]
    try
        a = tick_run("a", 7)
        b = tick_run("b", 7)
        c = tick_run("c", 8)
        append!(runs, (a, b, c))
        @test isfile(joinpath(a, "RUN_COMPLETE")) &&
              isfile(joinpath(a, "clock_anchor.toml"))
        anchor = TelemetryCore.load_clock_anchor(a)
        @test anchor.mode == "tick" && anchor.horizon == DateTime(2035, 1, 1, 6) + Hour(6)
        @test !isfile(joinpath(a, "emitter_alive")) &&
              !isfile(joinpath(a, "receiver_alive"))
        # The claim: the same seed reproduces the telemetry record to the
        # byte; another seed draws other losses.
        @test products(a) == products(b)
        @test products(a) != products(c)
        # The metrics profile agrees apart from its wall-clock column.
        profile(dir) = select(
            TelemetryCore.read_table(joinpath(dir, "mission_profile.csv")),
            Not(:WallTime),
        )
        @test profile(a) == profile(b)
        # Production follows from the span alone: a segment whose content
        # interval ends at the horizon is not generated, and the batches
        # are the full ones.
        phys = cfg["physics"]
        total_sec = (0.25 + 0.1) * 86_400.0
        segments = round(Int, total_sec / phys["segment_duration_sec"]) - 1
        tx = TelemetryCore.read_table(joinpath(a, "events_tx.csv"))
        @test count(==("gen"), tx.Event) == fld(segments, phys["batch_size"])
        @test maximum(tx.SimTime) < anchor.horizon
        # Every generated batch was served within the pass: the link
        # capacity exceeds production, and nothing is stamped past the
        # horizon on the arrival side either.
        rx = TelemetryCore.read_table(joinpath(a, "events_rx.csv"))
        @test count(==("ingested"), rx.Event) + count(==("lost"), rx.Event) ==
              count(==("gen"), tx.Event)
        @test maximum(rx.SimTime) < anchor.horizon
        # The gap table of a lossy run: every lost batch is a hole of its own
        # rows, nothing else is missing from a synthetic record served in
        # full, and the holes are the rows no delivered batch covers.
        gaps = TelemetryCore.read_table(joinpath(a, "masks", "gaps.csv"))
        lost = Set(String.(rx.Batch[rx.Event .== "lost"]))
        @test Set(String.(skipmissing(gaps.Batch))) == lost
        @test all(==("lost"), gaps.Cause)
        points =
            round(Int, phys["sample_rate"] * phys["segment_duration_sec"]) *
            phys["batch_size"]
        @test all(gaps.RowLast .- gaps.RowFirst .+ 1 .== points)
        first_row = TelemetryCore.batch_payload_rows(a)
        generated = Set(String.(tx.Batch[tx.Event .== "gen"]))
        n_rows = maximum(first_row[b] for b in generated) + points - 1
        covered = falses(n_rows)
        for name in setdiff(generated, lost)
            covered[first_row[name]:(first_row[name]+points-1)] .= true
        end
        declared = falses(n_rows)
        for r in eachrow(gaps)
            declared[r.RowFirst:r.RowLast] .= true
        end
        @test declared == .!covered
        @test Masks.gap_table(a) == gaps
    finally
        foreach(dir -> rm(dir; recursive = true, force = true), runs)
    end
end
