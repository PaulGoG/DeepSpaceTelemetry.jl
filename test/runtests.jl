# The suite runs in its own environment (test/Project.toml, with the parent
# package dev'ed at a relative path) and loads DeepSpaceTelemetry as a real
# package — never via include — so Aqua/JET/ExplicitImports resolve the
# package identity and `Pkg.test`'s sandbox agrees with a direct
# `julia --project=. test/runtests.jl` invocation.
using Pkg;
Pkg.activate(@__DIR__; io = devnull);
Pkg.instantiate(; io = devnull)
using Test, Dates, Statistics, CSV, DataFrames, Logging, Random, FFTW, TOML
using StableRNGs
using Aqua, JET, ExplicitImports
using DeepSpaceTelemetry
using DeepSpaceTelemetry:
    TelemetryCore,
    ChannelEffects,
    VirtualInstrument,
    Emitter,
    Receiver,
    PlotTheme,
    Supervisor

# The entire suite writes its runs into a disposable data root: the real
# data/ tree stays untouched even if the process is killed mid-suite.
TelemetryCore.DATA_ROOT[] = mktempdir()

@testset "Static QA (Aqua)" begin
    # Scripts and benchmarks carry their own environments (scripts/Project.toml,
    # bench/Project.toml), so the package dependency graph is exactly what
    # src/ loads and the stale-deps check runs unexempted.
    #
    # The persistent-tasks check generates a wrapper package resolved against
    # the live registry and precompiles it under the parent's flags. On the
    # GitHub runners that recompiles the whole stack in coverage mode and the
    # wrapper process then exits without a status file or any error output
    # (2026-09-07, both matrix jobs), while the identical invocation passes
    # locally. The check therefore runs everywhere except CI; the property
    # itself holds by construction — `__init__` only assigns DATA_ROOT and no
    # task is started at load.
    Aqua.test_all(DeepSpaceTelemetry; persistent_tasks = get(ENV, "CI", "") != "true")
end

@testset "Static QA (ExplicitImports)" begin
    @test ExplicitImports.check_no_stale_explicit_imports(DeepSpaceTelemetry) === nothing
    @test ExplicitImports.check_no_implicit_imports(DeepSpaceTelemetry) === nothing
end

@testset "Static QA (JET)" begin
    # Reports are restricted to this package's own modules; upstream
    # dependencies are analyzed but not reported against.
    JET.test_package(
        DeepSpaceTelemetry;
        target_modules = (
            DeepSpaceTelemetry,
            TelemetryCore,
            ChannelEffects,
            VirtualInstrument,
            PlotTheme,
            Emitter,
            Receiver,
            Supervisor,
        ),
    )
end

@testset "SimulationClock" begin
    start = now()
    clock = TelemetryCore.SimulationClock(start, start, 1.0)
    sleep(0.05)
    sim_t = TelemetryCore.get_current_sim_time(clock)
    @test sim_t > start
end

@testset "VisibilityModel" begin
    start = Time(12, 0, 0)
    dur = Second(8 * 3600)

    # 1. Sine profile
    model = TelemetryCore.VisibilityModel(start, dur, "sine")
    @test TelemetryCore.is_visible(model, DateTime(2030, 1, 1, 14, 0, 0)) == true
    @test TelemetryCore.is_visible(model, DateTime(2030, 1, 1, 10, 0, 0)) == false

    # Test values in [0,1] for all profiles
    profiles = ["sine", "sigmoid", "gaussian", "flat"]
    test_dt = DateTime(2030, 1, 1, 16, 0, 0) # Midpoint

    for p in profiles
        m = TelemetryCore.VisibilityModel(start, dur, p)
        val = TelemetryCore.get_bandwidth_factor(m, test_dt)
        @test 0.0 <= val <= 1.0

        # Sine should peak near midpoint
        if p == "sine"
            @test isapprox(val, 1.0, atol = 0.01)
        end
    end
end

@testset "Storage safety (legacy simulation.max_storage_gb fallback)" begin
    cfg_oversized = Dict(
        "simulation" => Dict(
            "speed_up" => 1.0,
            "mission_wall_seconds" => 1000000.0,
            "max_storage_gb" => 0.0001,
        ),
        "physics" => Dict(
            "segment_duration_sec" => 60.0,
            "sample_rate" => 1024.0,
            "batch_size" => 15,
        ),
    )
    @test_throws ErrorException TelemetryCore.check_storage_limits(cfg_oversized)
    @test TelemetryCore.storage_budget(cfg_oversized).max_gb == 0.0001

    cfg_safe = Dict(
        "simulation" => Dict(
            "speed_up" => 1.0,
            "mission_wall_seconds" => 100.0,
            "max_storage_gb" => 10.0,
        ),
        "physics" => Dict(
            "segment_duration_sec" => 60.0,
            "sample_rate" => 1024.0,
            "batch_size" => 15,
        ),
    )
    # Should not throw
    TelemetryCore.check_storage_limits(cfg_safe)
    @test true
end

# Complete, in-range configuration used as the mutation baseline below.
function valid_test_cfg()
    return Dict{String,Any}(
        "simulation" => Dict{String,Any}(
            "speed_up" => 3600.0,
            "mission_wall_seconds" => 10.0,
            "initial_downtime_days" => 0.0,
            "max_storage_gb" => 2.0,
            "start_sim_time" => "2035-01-01T06:00:00",
            "rng_seed" => 1,
        ),
        "telemetry" => Dict{String,Any}(
            "session_start" => "08:00:00",
            "session_duration_hours" => 8.0,
            "max_batches_per_hour" => 20.0,
            "bandwidth_profile" => "sine",
        ),
        "physics" => Dict{String,Any}(
            "data_source" => "synthetic",
            "sample_rate" => 4.0,
            "segment_duration_sec" => 60.0,
            "batch_size" => 10,
        ),
    )
end

@testset "Config validation: hard errors" begin
    @test TelemetryCore.validate_config(valid_test_cfg()) isa AbstractDict

    broken = [
        ("simulation", "speed_up", 0.0),
        ("simulation", "mission_wall_seconds", -1.0),
        ("simulation", "initial_downtime_days", -0.5),
        ("simulation", "max_storage_gb", 0.0),
        ("simulation", "rng_seed", "not-an-int"),
        ("telemetry", "session_duration_hours", 0.0),
        ("telemetry", "session_duration_hours", 25.0),
        ("telemetry", "max_batches_per_hour", 0.0),
        ("physics", "sample_rate", -4.0),
        ("physics", "segment_duration_sec", 0.0),
        ("physics", "batch_size", 0),
        ("physics", "data_source", "unsupported_source"),
        ("telemetry", "max_inflight_batches", 0),
        ("telemetry", "min_link_factor", 1.0),
        ("telemetry", "sigmoid_steepness", 0.0),
    ]
    for (section, key, val) in broken
        cfg = valid_test_cfg()
        cfg[section][key] = val
        @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    end

    # Missing required keys are configuration errors, never invented defaults
    for (section, key) in [
        ("simulation", "speed_up"),
        ("telemetry", "session_start"),
        ("physics", "batch_size"),
    ]
        cfg = valid_test_cfg()
        delete!(cfg[section], key)
        @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    end

    # FFT synthesis needs ≥ 2 samples per segment
    cfg = valid_test_cfg()
    cfg["physics"]["sample_rate"] = 0.01
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)

    # external source requires an existing file
    cfg = valid_test_cfg()
    cfg["physics"]["data_source"] = "external"
    cfg["physics"]["external_data_path"] = "definitely/not/a/file.csv"
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)

    # packet-loss corner cases
    for (key, val) in [("p_loss", 1.5), ("p_loss", -0.1), ("max_retries", -1)]
        cfg = valid_test_cfg()
        cfg["packet_loss"] =
            Dict{String,Any}("enabled" => true, "model" => "bernoulli", key => val)
        @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    end
    cfg = valid_test_cfg()
    cfg["packet_loss"] = Dict{String,Any}("enabled" => true, "model" => "unsupported_model")
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    cfg = valid_test_cfg()
    cfg["packet_loss"] =
        Dict{String,Any}("enabled" => true, "on_loss" => "unsupported_policy")
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)

    # disruption corner cases
    for ev in [
        Dict("start_day" => -1.0),
        Dict("start_day" => 0.1, "duration_hours" => 0.0),
        Dict("start_day" => 0.1, "recovery_hours" => -2.0),
        Dict("start_day" => 0.1, "severity" => 1.5),
    ]
        cfg = valid_test_cfg()
        cfg["disruption"] = Dict{String,Any}("events" => [ev])
        @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    end

    # legacy [disaster] section still validated (deprecation warning + same rules)
    cfg = valid_test_cfg()
    cfg["disaster"] = Dict{String,Any}("events" => [Dict("start_day" => -1.0)])
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)

    # a malformed [packet_loss] section is rejected even while disabled:
    # types, enumerations, and bounds must fail fast, never lie dormant
    cfg = valid_test_cfg()
    cfg["packet_loss"] =
        Dict{String,Any}("enabled" => false, "model" => "unsupported_model")
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)
end

@testset "Config validation: warnings" begin
    # Emitter pacing: 60 s segments at 10^6× → 0.06 ms real period
    cfg = valid_test_cfg()
    cfg["simulation"]["speed_up"] = 1.0e6
    @test_logs (:warn, r"cannot keep pace") match_mode=:any TelemetryCore.validate_config(
        cfg,
    )

    # Unknown bandwidth profile falls back with a warning
    cfg = valid_test_cfg()
    cfg["telemetry"]["bandwidth_profile"] = "trapezoid"
    @test_logs (:warn,) match_mode=:any TelemetryCore.validate_config(cfg)

    # Disruption scheduled after mission end never fires
    cfg = valid_test_cfg()
    cfg["disruption"] =
        Dict{String,Any}("events" => [Dict{String,Any}("start_day" => 100.0)])
    @test_logs (:warn,) match_mode=:any TelemetryCore.validate_config(cfg)

    # Gilbert–Elliott channel that never recovers
    cfg = valid_test_cfg()
    cfg["packet_loss"] = Dict{String,Any}(
        "enabled" => true,
        "model" => "gilbert_elliott",
        "p_bad_to_good" => 0.0,
    )
    @test_logs (:warn,) match_mode=:any TelemetryCore.validate_config(cfg)
end

@testset "Silent-failure guards" begin
    # Unrecognized keys and sections warn instead of silently defaulting
    cfg = valid_test_cfg()
    cfg["simulation"]["speedup"] = 7200.0 # typo'd key
    @test_logs (:warn, r"Unrecognized key simulation\.speedup") match_mode = :any TelemetryCore.validate_config(
        cfg,
    )
    cfg = valid_test_cfg()
    cfg["simulaton"] = Dict{String,Any}("speed_up" => 2.0) # typo'd section
    @test_logs (:warn, r"Unrecognized section") match_mode = :any TelemetryCore.validate_config(
        cfg,
    )
    cfg = valid_test_cfg()
    cfg["disruption"] = Dict{String,Any}(
        "events" => [Dict{String,Any}("start_day" => 0.1, "duration_hurs" => 5.0)],
    ) # typo'd event key
    @test_logs (:warn, r"Unrecognized key disruption\.events\[1\]\.duration_hurs") match_mode =
        :any TelemetryCore.validate_config(cfg)

    # Never-fires boundary is inclusive: an event at the exact final instant warns
    cfg = valid_test_cfg() # 10 s × 3600 → 10 mission hours
    mission_days = 10.0 * 3600.0 / 86_400.0
    cfg["disruption"] =
        Dict{String,Any}("events" => [Dict{String,Any}("start_day" => mission_days)])
    @test_logs (:warn, r"never fires") match_mode = :any TelemetryCore.validate_config(cfg)

    # Blackout + recovery tail truncated by mission end warns
    cfg = valid_test_cfg()
    cfg["disruption"] = Dict{String,Any}(
        "events" => [
            Dict{String,Any}(
                "start_day" => 0.2,
                "duration_hours" => 2.0,
                "recovery_hours" => 24.0,
                "severity" => 0.5,
            ),
        ],
    )
    @test_logs (:warn, r"truncated") match_mode = :any TelemetryCore.validate_config(cfg)

    # Overlapping events warn and state the composition semantics
    cfg = valid_test_cfg()
    cfg["disruption"] = Dict{String,Any}(
        "events" => [
            Dict{String,Any}(
                "start_day" => 0.05,
                "duration_hours" => 3.0,
                "severity" => 0.5,
            ),
            Dict{String,Any}(
                "start_day" => 0.1,
                "duration_hours" => 2.0,
                "severity" => 0.9,
            ),
        ],
    )
    @test_logs (:warn, r"overlap") match_mode = :any TelemetryCore.validate_config(cfg)

    # Loss saturation: worst-state per-attempt loss × largest disruption
    # multiplier ≥ 1 warns (0.4 × 3 ≥ 1 here)
    cfg = valid_test_cfg()
    cfg["packet_loss"] =
        Dict{String,Any}("enabled" => true, "model" => "bernoulli", "p_loss" => 0.4)
    cfg["disruption"] = Dict{String,Any}(
        "events" => [
            Dict{String,Any}(
                "start_day" => 0.01,
                "duration_hours" => 1.0,
                "loss_multiplier" => 3.0,
            ),
        ],
    )
    @test_logs (:warn, r"Loss saturation") match_mode = :any TelemetryCore.validate_config(
        cfg,
    )

    # Run-ID reuse guard: a second setup on a non-empty run directory refuses
    reuse_id = "TEST_RUN_reuse_pid$(getpid())"
    run_dir = TelemetryCore.setup_run_dir(reuse_id; cfg = valid_test_cfg())
    try
        @test_throws ErrorException TelemetryCore.setup_run_dir(reuse_id)
        # Platform provenance is stamped into every snapshot
        snap = TOML.parsefile(joinpath(run_dir, "config_snapshot.toml"))
        @test haskey(snap, "provenance") && haskey(snap["provenance"], "platform")
        @test haskey(snap["provenance"]["platform"], "hostname")
        @test snap["provenance"]["platform"]["julia_version"] == string(VERSION)
    finally
        rm(run_dir; recursive = true, force = true)
    end
end

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
        @test_throws ErrorException TelemetryCore.load_clock_anchor(joinpath(tmp, "absent"))
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
                    start_sim,
                    halt_id;
                    sample_rate = 4.0,
                    seg_dur = 60.0,
                    batch_size = 3,
                    initial_downtime_days = 0.01,
                    data_source = "external",
                    ext_path = ext_path,
                )
            end
            clock = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            em = Threads.@spawn with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    halt_id;
                    deadline = now() + Second(30),
                    sample_rate = 4.0,
                    seg_dur = 60.0,
                    batch_size = 3,
                    data_source = "external",
                    ext_path = ext_path,
                    instrument = vi,
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
                    start_sim,
                    cap_id;
                    sample_rate = 4.0,
                    seg_dur = 60.0,
                    batch_size = 3,
                    initial_downtime_days = 0.01,
                    data_source = "external",
                    ext_path = ext_path,
                )
            end
            clock = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    cap_id;
                    deadline = now() + Second(3),
                    sample_rate = 4.0,
                    seg_dur = 60.0,
                    batch_size = 3,
                    data_source = "external",
                    ext_path = ext_path,
                    instrument = vi,
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
                    start_sim,
                    floor_id;
                    sample_rate = 4.0,
                    seg_dur = 60.0,
                    batch_size = 3,
                    initial_downtime_days = 0.01,
                    data_source = "external",
                    ext_path = ext_path,
                )
            end
            clock = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            em = Threads.@spawn with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    floor_id;
                    deadline = now() + Second(4),
                    sample_rate = 4.0,
                    seg_dur = 60.0,
                    batch_size = 3,
                    data_source = "external",
                    ext_path = ext_path,
                    instrument = vi,
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
                    start_sim,
                    ra_id;
                    sample_rate = 4.0,
                    seg_dur = 60.0,
                    batch_size = 3,
                    initial_downtime_days = 0.01,
                    data_source = "external",
                    ext_path = ext_path,
                )
            end
            clock1 = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            TelemetryCore.save_clock_anchor(ra_dir, clock1, now() + Second(120))

            run_phase =
                (clk, instrument, segs, rng) -> begin
                    em = Threads.@spawn with_logger(NullLogger()) do
                        Emitter.run_emitter(
                            clk,
                            link,
                            ra_id;
                            deadline = now() + Second(3),
                            sample_rate = 4.0,
                            seg_dur = 60.0,
                            batch_size = 3,
                            data_source = "external",
                            ext_path = ext_path,
                            instrument = instrument,
                            pending_segments = segs,
                            rng = rng,
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

            run_phase(clock1, vi, pending, StableRNG(1))
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

            run_phase(restored.clock, nothing, TelemetryCore.DataSegment[], StableRNG(99))

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
                Receiver.generate_telemetry_masks(ra_dir)
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

@testset "Storage governance (estimator + mitigation-aware gate)" begin
    base = Dict{String,Any}(
        "simulation" => Dict{String,Any}(
            "speed_up" => 1.0,
            "mission_wall_seconds" => 100.0,
            "initial_downtime_days" => 0.0,
        ),
        "physics" => Dict{String,Any}(
            "segment_duration_sec" => 10.0,
            "sample_rate" => 2.0,
            "batch_size" => 5,
        ),
        "post_processing" => Dict{String,Any}(
            "generate_mask_timeline" => false,
            "expand_to_pointwise_masks" => false,
        ),
        "storage" => Dict{String,Any}("max_storage_gb" => 10.0),
    )

    # Closed-form artifact counts
    est = TelemetryCore.estimate_artifacts(base)
    @test est.n_segments == 10                 # 100 s / 10 s segments
    @test est.n_batches == 2                   # 10 segments / 5 per batch
    @test est.n_points == 200                  # 10 × 10 s × 2 Hz
    @test est.payload_bytes ≈ 200 * 15.0 rtol = 1e-12
    @test est.prunable_bytes == est.payload_bytes
    @test est.mask_bytes == 0.0
    @test est.pointwise_bytes == 0.0
    @test est.file_count > 0

    # Calibration override propagates
    base["storage"]["bytes_per_sample"] = 30.0
    @test TelemetryCore.estimate_artifacts(base).payload_bytes ≈ 200 * 30.0 rtol = 1e-12
    delete!(base["storage"], "bytes_per_sample")

    # Gate matrix — under budget, retention off: pass
    TelemetryCore.check_storage_limits(deepcopy(base))
    @test true

    # Over budget, retention off: hard stop
    over = deepcopy(base)
    over["storage"]["max_storage_gb"] = 1.0e-8
    @test_throws ErrorException TelemetryCore.check_storage_limits(over)

    # Over budget, retention on, steady state also over: hard stop
    over_steady = deepcopy(over)
    over_steady["retention"] =
        Dict{String,Any}("enabled" => true, "high_watermark_gb" => 1.0e-9)
    @test_throws ErrorException TelemetryCore.check_storage_limits(over_steady)

    # Unbounded projection over budget, retention bounds the steady state: pass
    mitigated = deepcopy(base)
    mitigated["storage"]["max_storage_gb"] =
        (est.total_bytes - est.prunable_bytes + 1000.0) / 1024^3
    mitigated["retention"] = Dict{String,Any}(
        "enabled" => true,
        "high_watermark_gb" => 500.0 / 1024^3,
        "grace_hours" => 1.0e-9,
    )
    @test_logs (:warn, r"retention bounds the steady state") match_mode = :any TelemetryCore.check_storage_limits(
        mitigated,
    )

    # File-count budget, retention off: hard stop
    over_files = deepcopy(base)
    over_files["storage"]["max_file_count"] = 3
    @test_throws ErrorException TelemetryCore.check_storage_limits(over_files)

    # retention_settings defaults (disabled custodian, 75 % watermark)
    r = TelemetryCore.retention_settings(base)
    @test r isa TelemetryCore.RetentionPolicy
    @test r.enabled == false
    @test r.grace == Millisecond(Dates.Hour(24))
    @test r.watermark_bytes ≈ 0.75 * 10.0 * 1024^3 rtol = 1e-12

    # validate_config rejects a watermark above the storage budget
    bad = valid_test_cfg()
    bad["storage"] = Dict{String,Any}("max_storage_gb" => 1.0)
    bad["retention"] = Dict{String,Any}("enabled" => true, "high_watermark_gb" => 2.0)
    @test_throws ArgumentError TelemetryCore.validate_config(bad)
end

@testset "Config guardrails (malformed inputs)" begin
    # Type-mismatched values abort with a clean [CONFIG] error, not a raw
    # conversion stacktrace
    for (sec, key, val) in [
        ("simulation", "speed_up", "3600"),
        ("simulation", "rng_seed", true),
        ("physics", "batch_size", 2.5),
        ("physics", "data_source", 5),
        ("telemetry", "max_batches_per_hour", "many"),
    ]
        cfg = valid_test_cfg()
        cfg[sec][key] = val
        @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    end
    cfg = valid_test_cfg()
    cfg["packet_loss"] = Dict{String,Any}("enabled" => true, "p_loss" => "high")
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    cfg = valid_test_cfg()
    cfg["disruption"] =
        Dict{String,Any}("events" => [Dict{String,Any}("start_day" => "ten")])
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)

    # The builders re-check defensively (reachable via legacy run snapshots
    # that never pass through validate_config)
    start = DateTime(2035, 1, 1)
    bad_ev = Dict{String,Any}(
        "disruption" =>
            Dict{String,Any}("events" => [Dict{String,Any}("start_day" => "ten")]),
    )
    @test_throws ArgumentError ChannelEffects.build_disruption_timeline(bad_ev, start)
    @test_throws ArgumentError ChannelEffects.build_loss_model(
        Dict{String,Any}(
            "packet_loss" => Dict{String,Any}("enabled" => true, "p_loss" => "high"),
        ),
        1,
    )

    # Relative config paths resolve against PROJECT_ROOT (the test process
    # does not run from the package root — exactly the regression condition)
    @test TelemetryCore.load_config("config.toml") isa AbstractDict

    # Malformed TOML: hard stop for the live config, warn + fallback to the
    # project config for run snapshots (post-processing must not die)
    mktempdir() do dir
        bad_toml = joinpath(dir, "config.toml")
        write(bad_toml, "[simulation\nspeed_up = ")
        @test_throws ErrorException TelemetryCore.load_config(bad_toml)

        run_dir = joinpath(dir, "run")
        mkpath(run_dir)
        write(joinpath(run_dir, "config_snapshot.toml"), "[simulation\nspeed_up = ")
        cfg_fb = @test_logs (:warn,) match_mode=:any TelemetryCore.load_run_config(run_dir)
        @test cfg_fb isa AbstractDict && haskey(cfg_fb, "simulation")
    end
end

@testset "ChannelEffects: loss models" begin
    # NoLoss never loses
    @test !any(ChannelEffects.sample_loss!(ChannelEffects.NoLoss()) for _ in 1:100)
    @test ChannelEffects.stationary_loss_rate(ChannelEffects.NoLoss()) == 0.0

    # Bernoulli: empirical rate matches p (seeded)
    m = ChannelEffects.BernoulliLoss(0.2, StableRNG(7))
    n = 200_000
    rate = count(_ -> ChannelEffects.sample_loss!(m), 1:n) / n
    @test isapprox(rate, 0.2, rtol = 0.05)
    @test ChannelEffects.stationary_loss_rate(m) == 0.2

    # Multiplier scaling and clamping
    m_hi = ChannelEffects.BernoulliLoss(0.5, StableRNG(1))
    @test all(ChannelEffects.sample_loss!(m_hi; multiplier = 10.0) for _ in 1:200) # 0.5×10 → 1
    m_lo = ChannelEffects.BernoulliLoss(0.5, StableRNG(1))
    @test !any(ChannelEffects.sample_loss!(m_lo; multiplier = 0.0) for _ in 1:200)

    # Gilbert–Elliott: sampled long-run rate matches the analytic stationary rate
    gilbert_elliott =
        ChannelEffects.GilbertElliottLoss(0.05, 0.25, 0.01, 0.5, false, StableRNG(11))
    expected = ChannelEffects.stationary_loss_rate(gilbert_elliott)
    @test isapprox(expected, (0.05 / 0.30) * 0.5 + (0.25 / 0.30) * 0.01; rtol = 1e-12)
    n = 400_000
    rate = count(_ -> ChannelEffects.sample_loss!(gilbert_elliott), 1:n) / n
    @test isapprox(rate, expected, rtol = 0.05)

    # Determinism: identical seeds → identical realizations
    a = ChannelEffects.GilbertElliottLoss(0.1, 0.3, 0.01, 0.6, false, StableRNG(3))
    b = ChannelEffects.GilbertElliottLoss(0.1, 0.3, 0.01, 0.6, false, StableRNG(3))
    @test [ChannelEffects.sample_loss!(a) for _ in 1:1000] == [ChannelEffects.sample_loss!(b) for _ in 1:1000]

    # Burstiness: loss events must cluster (conditional loss probability after
    # a loss far exceeds the marginal rate for a strongly two-sided channel)
    gb = ChannelEffects.GilbertElliottLoss(0.02, 0.2, 0.001, 0.8, false, StableRNG(21))
    draws = [ChannelEffects.sample_loss!(gb) for _ in 1:200_000]
    marginal = mean(draws)
    after_loss = mean(draws[i+1] for i in 1:(length(draws)-1) if draws[i])
    @test after_loss > 2 * marginal
end

@testset "ChannelEffects: disruption timeline" begin
    start = DateTime(2035, 1, 1)
    cfg = Dict{String,Any}(
        "disruption" => Dict{String,Any}(
            "events" => [
                Dict{String,Any}(
                    "type" => "link_disruption",
                    "label" => "solar flare",
                    "start_day" => 1.0,
                    "duration_hours" => 24.0,
                    "recovery_hours" => 12.0,
                    "severity" => 1.0,
                    "loss_multiplier" => 5.0,
                ),
            ],
        ),
    )
    tl = ChannelEffects.build_disruption_timeline(cfg, start)

    @test ChannelEffects.disruption_factor(tl, start) == 1.0                          # before
    @test ChannelEffects.disruption_factor(tl, start + Day(1)) == 0.0                 # blackout onset
    @test ChannelEffects.disruption_factor(tl, start + Day(1) + Hour(23)) == 0.0      # deep blackout
    @test isapprox(
        ChannelEffects.disruption_factor(tl, start + Day(2) + Hour(6)),
        0.5,
        atol = 1e-9,
    ) # mid-ramp
    @test ChannelEffects.disruption_factor(tl, start + Day(2) + Hour(12)) == 1.0      # recovered

    # Ramp is monotone non-decreasing
    ts = [start + Day(2) + Minute(m) for m in 0:30:720]
    @test issorted([ChannelEffects.disruption_factor(tl, t) for t in ts])

    # Loss multiplier active through blackout AND recovery, off outside
    @test ChannelEffects.disruption_loss_multiplier(tl, start + Day(1) + Hour(5)) == 5.0
    @test ChannelEffects.disruption_loss_multiplier(tl, start + Day(2) + Hour(6)) == 5.0
    @test ChannelEffects.disruption_loss_multiplier(tl, start + Day(3)) == 1.0
    @test ChannelEffects.disruption_loss_multiplier(tl, start) == 1.0

    # Optional display label: set while active, "" outside / when unlabeled
    @test ChannelEffects.active_disruption_label(tl, start + Day(1) + Hour(5)) ==
          "solar flare"
    @test ChannelEffects.active_disruption_label(tl, start) == ""

    # Partial severity degrades instead of blacking out
    cfg2 = Dict{String,Any}(
        "disruption" => Dict{String,Any}(
            "events" => [
                Dict{String,Any}(
                    "start_day" => 0.0,
                    "duration_hours" => 12.0,
                    "severity" => 0.4,
                ),
            ],
        ),
    )
    tl2 = ChannelEffects.build_disruption_timeline(cfg2, start)
    @test isapprox(ChannelEffects.disruption_factor(tl2, start + Hour(6)), 0.6, atol = 1e-9)
    @test ChannelEffects.active_disruption_label(tl2, start + Hour(6)) == ""

    # Legacy [disaster] section name (pre-rename run snapshots) still parses
    legacy = Dict{String,Any}(
        "disaster" => Dict{String,Any}(
            "events" => [
                Dict{String,Any}(
                    "start_day" => 0.0,
                    "duration_hours" => 12.0,
                    "severity" => 0.4,
                ),
            ],
        ),
    )
    tl_legacy = ChannelEffects.build_disruption_timeline(legacy, start)
    @test isapprox(
        ChannelEffects.disruption_factor(tl_legacy, start + Hour(6)),
        0.6,
        atol = 1e-9,
    )

    # Empty timeline is a no-op
    @test ChannelEffects.disruption_factor(ChannelEffects.DisruptionTimeline(), start) ==
          1.0

    # Malformed events abort
    bad = Dict{String,Any}(
        "disruption" =>
            Dict{String,Any}("events" => [Dict{String,Any}("start_day" => -1.0)]),
    )
    @test_throws ArgumentError ChannelEffects.build_disruption_timeline(bad, start)
end

@testset "ChannelEffects: LinkModel composition" begin
    cfg = valid_test_cfg()
    cfg["disruption"] = Dict{String,Any}(
        "events" => [
            Dict{String,Any}(
                "start_day" => 0.0,
                "duration_hours" => 4.0,
                "severity" => 1.0,
            ),
        ],
    ) # 06:00–10:00 blackout
    cfg["telemetry"]["bandwidth_profile"] = "flat"
    link = ChannelEffects.build_link_model(cfg)

    # 09:00 — inside session (08–16) but inside blackout: dead link
    @test ChannelEffects.effective_bandwidth(link, DateTime(2035, 1, 1, 9, 0, 0)) == 0.0
    @test !ChannelEffects.is_transmittable(link, DateTime(2035, 1, 1, 9, 0, 0))
    # 12:00 — inside session, after blackout: full link
    @test ChannelEffects.effective_bandwidth(link, DateTime(2035, 1, 1, 12, 0, 0)) == 1.0
    @test ChannelEffects.is_transmittable(link, DateTime(2035, 1, 1, 12, 0, 0))
    # 07:00 — outside session: geometrically invisible
    @test ChannelEffects.effective_bandwidth(link, DateTime(2035, 1, 1, 7, 0, 0)) == 0.0
    @test !ChannelEffects.is_transmittable(link, DateTime(2035, 1, 1, 7, 0, 0))

    # Disruption-free convenience constructor
    plain = ChannelEffects.LinkModel(link.visibility)
    @test ChannelEffects.effective_bandwidth(plain, DateTime(2035, 1, 1, 9, 0, 0)) == 1.0
end

@testset "ChannelEffects: config builders" begin
    # Disabled / absent → NoLoss
    @test ChannelEffects.build_loss_model(Dict{String,Any}(), 1) isa ChannelEffects.NoLoss
    cfg = Dict{String,Any}(
        "packet_loss" => Dict{String,Any}("enabled" => false, "p_loss" => 0.9),
    )
    @test ChannelEffects.build_loss_model(cfg, 1) isa ChannelEffects.NoLoss

    cfg = Dict{String,Any}(
        "packet_loss" => Dict{String,Any}(
            "enabled" => true,
            "model" => "bernoulli",
            "p_loss" => 0.3,
        ),
    )
    m = ChannelEffects.build_loss_model(cfg, 1)
    @test m isa ChannelEffects.BernoulliLoss && m.p == 0.3

    cfg = Dict{String,Any}(
        "packet_loss" => Dict{String,Any}(
            "enabled" => true,
            "model" => "gilbert_elliott",
            "p_good_to_bad" => 0.1,
            "p_bad_to_good" => 0.4,
            "p_loss_good" => 0.01,
            "p_loss_bad" => 0.5,
        ),
    )
    gilbert_elliott = ChannelEffects.build_loss_model(cfg, 1)
    @test gilbert_elliott isa ChannelEffects.GilbertElliottLoss &&
          gilbert_elliott.p_loss_bad == 0.5 &&
          !gilbert_elliott.in_bad_state

    @test_throws ArgumentError ChannelEffects.build_loss_model(
        Dict{String,Any}(
            "packet_loss" =>
                Dict{String,Any}("enabled" => true, "model" => "unsupported_model"),
        ),
        1,
    )
    @test_throws ArgumentError ChannelEffects.build_loss_model(
        Dict{String,Any}(
            "packet_loss" => Dict{String,Any}("enabled" => true, "p_loss" => 1.5),
        ),
        1,
    )

    # Retry policy resolution
    @test ChannelEffects.loss_retry_limit(Dict{String,Any}()) == 3
    @test ChannelEffects.loss_retry_limit(
        Dict{String,Any}(
            "packet_loss" => Dict{String,Any}("on_loss" => "drop", "max_retries" => 7),
        ),
    ) == 0
    @test ChannelEffects.loss_retry_limit(
        Dict{String,Any}("packet_loss" => Dict{String,Any}("max_retries" => 7)),
    ) == 7
    @test_throws ArgumentError ChannelEffects.loss_retry_limit(
        Dict{String,Any}(
            "packet_loss" => Dict{String,Any}("on_loss" => "unsupported_policy"),
        ),
    )
end

@testset "Batch I/O" begin
    mktempdir() do tmp
        seg1 = TelemetryCore.DataSegment(1, DateTime(2030, 1, 1), Float32[1.0, 2.0, 3.0])
        seg2 =
            TelemetryCore.DataSegment(2, DateTime(2030, 1, 1, 0, 1), Float32[4.0, 5.0, 6.0])
        batch = TelemetryCore.DataBatch(100, [seg1, seg2], now())

        batch_dir = joinpath(tmp, "batch_100")
        TelemetryCore.save_batch(batch_dir, batch)

        @test isfile(joinpath(batch_dir, "metadata.json"))
        @test isfile(joinpath(batch_dir, "seg_1.csv"))
        @test isfile(joinpath(batch_dir, "seg_2.csv"))

        loaded_seg = TelemetryCore.load_segment(joinpath(batch_dir, "seg_1.csv"))
        @test loaded_seg.id == 1
        @test loaded_seg.data == Float32[1.0, 2.0, 3.0]
    end
end

@testset "Noise model (Robson, Cornish & Liu 2019)" begin
    # Independent evaluation of Eq. 1 and Eq. 14 with the paper's constants.
    L = 2.5e9
    f_star = 2.99792458e8 / (2π * L)
    p_oms(f) = (1.5e-11)^2 * (1 + (2e-3 / f)^4)
    p_acc(f) = (3e-15)^2 * (1 + (0.4e-3 / f)^2) * (1 + (f / 8e-3)^4)
    s_inst(f) =
        (10 / (3 * L^2)) *
        (p_oms(f) + 2 * (1 + cos(f / f_star)^2) * p_acc(f) / (2π * f)^4) *
        (1 + 0.6 * (f / f_star)^2)
    fits = Dict(
        0.5 => (0.133, 243.0, 482.0, 917.0, 0.00258),
        1.0 => (0.171, 292.0, 1020.0, 1680.0, 0.00215),
        2.0 => (0.165, 299.0, 611.0, 1340.0, 0.00173),
        4.0 => (0.138, -221.0, 521.0, 1680.0, 0.00113),
    )
    # The cutoff 1 + tanh(x) is written as 2 / (1 + exp(-2x)): the direct sum
    # cancels catastrophically above the knee (x ≈ -13 at 10 mHz).
    function s_conf(f, T)
        α, β, κ, γ, f_k = fits[T]
        return 9e-45 *
               f^(-7 / 3) *
               exp(-f^α + β * f * sin(κ * f)) *
               (2 / (1 + exp(-2 * γ * (f_k - f))))
    end
    for f in (1e-3, 3e-3, 1e-2)
        @test VirtualInstrument.lisa_instrument_psd(f) ≈ s_inst(f) rtol = 1e-12
        for T in (0.5, 1.0, 2.0, 4.0)
            @test VirtualInstrument.lisa_confusion_psd(f, T) ≈ s_conf(f, T) rtol = 1e-12
        end
        @test VirtualInstrument.lisa_noise_psd(f; observation_years = 2.0) ≈
              s_inst(f) + s_conf(f, 2.0) rtol = 1e-12
    end
    # Reference values of the paper's formulas [Hz⁻¹].
    @test VirtualInstrument.lisa_instrument_psd(1e-3) ≈ 1.634101e-38 rtol = 1e-6
    @test VirtualInstrument.lisa_instrument_psd(1e-2) ≈ 1.443169e-40 rtol = 1e-6
    @test VirtualInstrument.lisa_confusion_psd(1e-3, 1.0) ≈ 1.663516e-37 rtol = 1e-6
    # The confusion foreground dominates the instrument term at 1 mHz.
    @test VirtualInstrument.lisa_confusion_psd(1e-3, 1.0) > 0.0
    @test VirtualInstrument.lisa_confusion_psd(1e-3, 1.0) >
          VirtualInstrument.lisa_instrument_psd(1e-3)
    # Outside the model's domain: no floor value.
    @test VirtualInstrument.lisa_noise_psd(0.0) == Inf
    @test VirtualInstrument.lisa_noise_psd(-1.0) == Inf
    @test_throws ArgumentError VirtualInstrument.lisa_confusion_psd(1e-3, 3.0)
    @test_throws ArgumentError VirtualInstrument.InstrumentState(
        DateTime(2030),
        10.0,
        1.0,
        "synthetic",
        "";
        confusion_observation_years = 3.0,
    )
    @test_throws ArgumentError VirtualInstrument.InstrumentState(
        DateTime(2030),
        10.0,
        1.0,
        "synthetic",
        "";
        noise_f_min_hz = 0.0,
    )
    # Band floor: 40 samples at 4e-4 Hz give a bin spacing of 5e-6 Hz, so the
    # DC bin and the first bin lie below the 1e-5 Hz floor and carry no power.
    vi = VirtualInstrument.InstrumentState(
        DateTime(2030),
        4e-4,
        1e5,
        "synthetic",
        "";
        rng = StableRNG(1),
    )
    @test vi.noise_amp[1] == 0.0 && vi.noise_amp[2] == 0.0
    @test vi.noise_amp[4] > 0.0
    @test all(isfinite, vi.noise_amp)
    @test all(isfinite, VirtualInstrument.next_segment!(vi).data)
    # Configuration keys: defaults, accepted values, and rejections.
    cfg = valid_test_cfg()
    phys = TelemetryCore.physics_settings(cfg)
    @test phys.confusion_observation_years == 1.0 && phys.noise_f_min_hz == 1e-5
    cfg["physics"]["confusion_observation_years"] = 4
    cfg["physics"]["noise_f_min_hz"] = 2e-4
    phys = TelemetryCore.physics_settings(cfg)
    @test phys.confusion_observation_years == 4.0 && phys.noise_f_min_hz == 2e-4
    cfg["physics"]["confusion_observation_years"] = 3.0
    @test_throws ArgumentError TelemetryCore.physics_settings(cfg)
    cfg["physics"]["confusion_observation_years"] = 1.0
    cfg["physics"]["noise_f_min_hz"] = 0.0
    @test_throws ArgumentError TelemetryCore.physics_settings(cfg)
end

@testset "VirtualInstrument Synthetic" begin
    fs = 10.0
    seg_dur = 1.0
    n = 10
    start_t = DateTime(2030, 1, 1)
    vi = VirtualInstrument.InstrumentState(
        start_t,
        fs,
        seg_dur,
        "synthetic",
        "";
        rng = StableRNG(42),
    )

    seg1 = VirtualInstrument.next_segment!(vi)
    @test length(seg1.data) == n
    @test seg1.id == 1

    seg2 = VirtualInstrument.next_segment!(vi)
    @test seg2.id == 2

    # Amplitude calibration: the pooled variance of the stream must equal
    # ∫S(f)df over the representable band of the 2N-sample synthesis blocks
    # (Parseval, one-sided PSD with half-weighted Nyquist bin).
    block_len = 2n
    freqs = collect(rfftfreq(block_len, fs))
    S = VirtualInstrument.lisa_noise_psd.(freqs)
    expected_var = (fs / block_len) * (sum(S[2:(end-1)]) + S[end] / 2)
    vals = Float64[]
    for _ in 1:2000
        append!(vals, Float64.(VirtualInstrument.next_segment!(vi).data))
    end
    @test isapprox(var(vals), expected_var, rtol = 0.1)

    # Continuity: jumps across segment boundaries must be statistically
    # indistinguishable from jumps inside segments (no per-segment seams).
    segs = [VirtualInstrument.next_segment!(vi).data for _ in 1:200]
    boundary_jumps = [abs(Float64(segs[i+1][1]) - Float64(segs[i][end])) for i in 1:199]
    inner_jumps = Float64[]
    for s in segs
        append!(inner_jumps, abs.(diff(Float64.(s))))
    end
    @test mean(boundary_jumps) < 2 * mean(inner_jumps)
end

@testset "VirtualInstrument determinism (seeded RNG)" begin
    start_t = DateTime(2030, 1, 1)
    v1 = VirtualInstrument.InstrumentState(
        start_t,
        10.0,
        1.0,
        "synthetic",
        "";
        rng = StableRNG(99),
    )
    v2 = VirtualInstrument.InstrumentState(
        start_t,
        10.0,
        1.0,
        "synthetic",
        "";
        rng = StableRNG(99),
    )
    for _ in 1:5
        s1 = VirtualInstrument.next_segment!(v1)
        s2 = VirtualInstrument.next_segment!(v2)
        @test s1.data == s2.data
    end
    # Different seeds → different streams
    v3 = VirtualInstrument.InstrumentState(
        start_t,
        10.0,
        1.0,
        "synthetic",
        "";
        rng = StableRNG(100),
    )
    @test VirtualInstrument.next_segment!(v3).data !=
          VirtualInstrument.next_segment!(v1).data
end

@testset "VirtualInstrument External" begin
    # Relative external paths resolve against PROJECT_ROOT, not the CWD
    # (the test process runs from test/, exactly the regression condition)
    rel_name = joinpath("data", "tmp_test_ext_$(getpid()).csv")
    abs_name = joinpath(TelemetryCore.PROJECT_ROOT, rel_name)
    try
        CSV.write(abs_name, DataFrame(Amplitude = Float32[1.0, 2.0, 3.0, 4.0]))
        vi_rel = VirtualInstrument.InstrumentState(
            DateTime(2030, 1, 1),
            2.0,
            2.0,
            "external",
            rel_name,
        )
        @test vi_rel.ext_data == Float32[1.0, 2.0, 3.0, 4.0]
    finally
        rm(abs_name, force = true)
    end

    # Corner cases: non-numeric / empty external data abort with clean
    # [CONFIG] errors; mid-stream exhaustion pads with zeros and warns once
    mktempdir() do tmp
        txt_csv = joinpath(tmp, "text.csv")
        CSV.write(txt_csv, DataFrame(Amplitude = ["a", "b"]))
        @test_throws ArgumentError VirtualInstrument.InstrumentState(
            DateTime(2030, 1, 1),
            2.0,
            2.0,
            "external",
            txt_csv,
        )

        empty_csv = joinpath(tmp, "empty.csv")
        CSV.write(empty_csv, DataFrame(Amplitude = Float32[]))
        @test_throws ArgumentError VirtualInstrument.InstrumentState(
            DateTime(2030, 1, 1),
            2.0,
            2.0,
            "external",
            empty_csv,
        )

        short_csv = joinpath(tmp, "short.csv")
        CSV.write(short_csv, DataFrame(Amplitude = Float32[1, 2, 3, 4, 5, 6]))
        vi_s = VirtualInstrument.InstrumentState(
            DateTime(2030, 1, 1),
            2.0,
            2.0,
            "external",
            short_csv,
        )
        VirtualInstrument.next_segment!(vi_s)                     # samples 1–4: silent
        seg_pad = @test_logs (:warn,) match_mode=:any VirtualInstrument.next_segment!(vi_s)
        @test seg_pad.data == Float32[5.0, 6.0, 0.0, 0.0]         # 5–6 + zero padding
    end

    mktempdir() do tmp
        csv_path = joinpath(tmp, "ext.csv")
        df = DataFrame(Amplitude = Float32[0.1, 0.2, 0.3, 0.4, 0.5])
        CSV.write(csv_path, df)

        start_t = DateTime(2030, 1, 1)
        vi = VirtualInstrument.InstrumentState(start_t, 2.0, 2.0, "external", csv_path)

        seg1 = VirtualInstrument.next_segment!(vi)
        # Needs 4 samples (2.0 * 2.0). 0.1, 0.2, 0.3, 0.4
        @test length(seg1.data) == 4
        @test seg1.data == Float32[0.1, 0.2, 0.3, 0.4]

        seg2 = VirtualInstrument.next_segment!(vi)
        # Needs 4 samples. 0.5, then 0.0, 0.0, 0.0
        @test length(seg2.data) == 4
        @test seg2.data == Float32[0.5, 0.0, 0.0, 0.0]
    end
end

@testset "LIFO Ordering" begin
    # Archive-queue LIFO discipline: pushfirst! / popfirst!
    arch_queue = String[]
    pushfirst!(arch_queue, "ARCH_batch_1")
    pushfirst!(arch_queue, "ARCH_batch_2")
    pushfirst!(arch_queue, "ARCH_batch_3")

    # Popping should give newest first (LIFO)
    @test popfirst!(arch_queue) == "ARCH_batch_3"
    @test popfirst!(arch_queue) == "ARCH_batch_2"
    @test popfirst!(arch_queue) == "ARCH_batch_1"
end

@testset "normalize_target_rows" begin
    @test TelemetryCore.normalize_target_rows("all") === :all
    @test TelemetryCore.normalize_target_rows(["all"]) === :all
    @test TelemetryCore.normalize_target_rows([3, 1, 3]) == [1, 3]
    @test TelemetryCore.normalize_target_rows([-1]) == [-1]
    @test TelemetryCore.normalize_target_rows(["2:4", 7]) == [2, 3, 4, 7]
end

@testset "Midnight-wrapping visibility" begin
    m = TelemetryCore.VisibilityModel(Time(20, 0, 0), Second(8 * 3600), "flat")
    @test TelemetryCore.is_visible(m, DateTime(2030, 1, 1, 23, 0, 0))
    @test TelemetryCore.is_visible(m, DateTime(2030, 1, 2, 3, 0, 0))
    @test !TelemetryCore.is_visible(m, DateTime(2030, 1, 1, 12, 0, 0))
    @test TelemetryCore.get_bandwidth_factor(m, DateTime(2030, 1, 2, 2, 0, 0)) ≈ 1.0
    ms = TelemetryCore.VisibilityModel(Time(20, 0, 0), Second(8 * 3600), "sine")
    # Sine profile peaks at the session midpoint (midnight)
    @test isapprox(
        TelemetryCore.get_bandwidth_factor(ms, DateTime(2030, 1, 2, 0, 0, 0)),
        1.0,
        atol = 0.01,
    )
end

@testset "Bandwidth profile shapes and edges" begin
    start = Time(8, 0, 0)
    dur = Second(8 * 3600)
    mid = DateTime(2030, 1, 1, 12, 0, 0)
    edge = DateTime(2030, 1, 1, 8, 0, 0)

    # Documented sigmoid property: the profile does NOT vanish at the session
    # boundary — it opens at ≈ 0.5 (tanh(0) + tanh(k))/2.
    sig = TelemetryCore.VisibilityModel(start, dur, "sigmoid")
    @test isapprox(TelemetryCore.get_bandwidth_factor(sig, edge), 0.5, atol = 0.01)

    # Steepness monotonicity: a steeper sigmoid is closer to saturation at
    # quarter-session than a shallow one.
    quarter = DateTime(2030, 1, 1, 10, 0, 0)
    shallow = TelemetryCore.VisibilityModel(start, dur, "sigmoid", 3.0, 0.15)
    steep = TelemetryCore.VisibilityModel(start, dur, "sigmoid", 50.0, 0.15)
    @test TelemetryCore.get_bandwidth_factor(steep, quarter) >
          TelemetryCore.get_bandwidth_factor(shallow, quarter)

    # Gaussian: unit peak at mid-session; smaller sigma → narrower pass.
    narrow = TelemetryCore.VisibilityModel(start, dur, "gaussian", 10.0, 0.05)
    wide = TelemetryCore.VisibilityModel(start, dur, "gaussian", 10.0, 0.30)
    @test isapprox(TelemetryCore.get_bandwidth_factor(narrow, mid), 1.0, atol = 1e-6)
    @test TelemetryCore.get_bandwidth_factor(narrow, quarter) <
          TelemetryCore.get_bandwidth_factor(wide, quarter)

    # Three-argument constructor carries the documented default shapes.
    default_model = TelemetryCore.VisibilityModel(start, dur, "gaussian")
    @test default_model.sigmoid_steepness == 10.0
    @test default_model.gaussian_sigma == 0.15
end

@testset "Safe CSV write (backup rotation)" begin
    mktempdir() do tmp
        p = joinpath(tmp, "res.csv")
        TelemetryCore.safe_csv_write(p, DataFrame(a = [1]))
        TelemetryCore.safe_csv_write(p, DataFrame(a = [2]))
        TelemetryCore.safe_csv_write(p, DataFrame(a = [3]))
        @test isfile(joinpath(tmp, "res#1.csv"))
        @test isfile(joinpath(tmp, "res#2.csv"))
        @test CSV.read(p, DataFrame).a == [3]
        @test CSV.read(joinpath(tmp, "res#1.csv"), DataFrame).a == [1]
    end
end

@testset "Exact batch-state reconstruction from event logs" begin
    mktempdir() do tmp
        t0 = DateTime(2035, 1, 1)
        tx = DataFrame(
            SimTime = [t0 - Hour(1), t0 + Minute(1), t0 + Minute(2), t0 + Minute(3)],
            Batch = ["ARCH_batch_1", "LIVE_batch_2", "ARCH_batch_1", "LIVE_batch_2"],
            Event = ["gen", "gen", "tx", "tx"],
        )
        rx = DataFrame(
            SimTime = [t0 + Minute(4), t0 + Minute(5), t0 + Minute(6)],
            Batch = ["ARCH_batch_1", "LIVE_batch_2", "LIVE_batch_2"],
            Event = ["ingested", "retry", "lost"],
            Attempt = [0, 1, 2],
        )
        CSV.write(joinpath(tmp, "events_tx.csv"), tx)
        CSV.write(joinpath(tmp, "events_rx.csv"), rx)

        df = DataFrame(SimTime = [t0, t0 + Minute(2) + Second(30), t0 + Minute(10)])
        states = Receiver.reconstruct_batch_states(tmp, df)
        @test length(states) == 3

        # Row 1 (t0): batch 1 pre-populated onboard, batch 2 not yet generated
        @test states[1].onboard_archive == [1]
        @test isempty(states[1].onboard_live) && isempty(states[1].lost)
        # Row 2 (t0+2.5 min): batch 1 on the link, batch 2 onboard (retry events preserve state)
        @test states[2].link_archive == [1]
        @test states[2].onboard_live == [2]
        # Row 3 (t0+10 min): batch 1 grounded, batch 2 permanently lost
        @test states[3].ground_archive == [1]
        @test states[3].lost == [2]
        @test isempty(states[3].link_live) && isempty(states[3].link_archive)

        # The dispatcher picks the exact reconstruction when logs exist
        vis = TelemetryCore.VisibilityModel(Time(8, 0, 0), Second(8 * 3600), "flat")
        @test Receiver.batch_states(tmp, df) == states
    end
end

@testset "Event-replay tolerance (pruned + unknown events)" begin
    # A newer run's event log must never abort an older toolchain's replay:
    # `pruned` is state-preserving and unknown event names are skipped with a
    # warning, leaving the delivery state untouched.
    mktempdir() do tmp
        t0 = DateTime(2035, 1, 1, 8, 0, 0)
        tx = DataFrame(
            SimTime = [t0, t0 + Minute(1), t0 + Minute(9)],
            Batch = ["LIVE_batch_1", "LIVE_batch_1", "LIVE_batch_1"],
            Event = ["gen", "tx", "future_tx_event"],
        )
        rx = DataFrame(
            SimTime = [t0 + Minute(2), t0 + Minute(3), t0 + Minute(4)],
            Batch = ["LIVE_batch_1", "LIVE_batch_1", "LIVE_batch_1"],
            Event = ["ingested", "pruned", "future_rx_event"],
            Attempt = [0, 0, 0],
        )
        CSV.write(joinpath(tmp, "events_tx.csv"), tx)
        CSV.write(joinpath(tmp, "events_rx.csv"), rx)
        df = DataFrame(SimTime = [t0 + Minute(30)])
        states = with_logger(NullLogger()) do
            Receiver.reconstruct_batch_states(tmp, df)
        end
        @test length(states) == 1
        @test states[1].ground_live == [1]  # delivery state unperturbed
        @test isempty(states[1].lost)
    end

    # Cross-component timestamp skew: emitter and receiver stamp milestones
    # from separate clock reads, so an `ingested` record can carry an earlier
    # timestamp than its own `tx` record at high speed-up. Per-batch causal
    # order must win: the state sequence never regresses.
    mktempdir() do tmp
        t0 = DateTime(2035, 1, 1, 8, 0, 0)
        tx = DataFrame(
            SimTime = [t0, t0 + Minute(5)],
            Batch = ["LIVE_batch_1", "LIVE_batch_1"],
            Event = ["gen", "tx"], # tx recorded AFTER the receiver's ingested
        )
        rx = DataFrame(
            SimTime = [t0 + Minute(3)],
            Batch = ["LIVE_batch_1"],
            Event = ["ingested"],
            Attempt = [0],
        )
        CSV.write(joinpath(tmp, "events_tx.csv"), tx)
        CSV.write(joinpath(tmp, "events_rx.csv"), rx)
        df = DataFrame(
            SimTime = [t0 + Minute(1), t0 + Minute(4), t0 + Minute(6), t0 + Minute(8)],
        )
        states = with_logger(NullLogger()) do
            Receiver.reconstruct_batch_states(tmp, df)
        end
        @test states[2].ground_live == [1] # delivered at the ingested record
        @test states[3].ground_live == [1] # the late-stamped tx cannot regress it
        @test states[4].ground_live == [1]
        @test isempty(states[3].link_live)
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
                    start_sim,
                    run_id;
                    sample_rate = sample_rate,
                    seg_dur = seg_dur,
                    batch_size = 3,
                    initial_downtime_days = 0.02,
                    data_source = "external",
                    ext_path = ext_path,
                )
            end

            arch_batches = filter(
                f -> startswith(f, "ARCH_batch_"),
                readdir(joinpath(run_dir, "onboard")),
            )
            @test length(arch_batches) == 9
            @test vi.last_t >= start_sim
            # Stream continuity: instrument consumed exactly 29 segments...
            @test vi.ext_index == 29 * n_per_seg + 1
            # ...and the partial batch carries segments 28-29 for the main loop
            @test length(pending) == 2
            @test pending[1].data[1] == Float32(27 * n_per_seg + 1)

            clock = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            em = Threads.@spawn with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    run_id;
                    deadline = now() + Second(6),
                    sample_rate = sample_rate,
                    seg_dur = seg_dur,
                    batch_size = 3,
                    data_source = "external",
                    ext_path = ext_path,
                    instrument = vi,
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

            Receiver.generate_telemetry_masks(run_dir)
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
                    start_sim,
                    run_id;
                    sample_rate = 4.0,
                    seg_dur = 60.0,
                    batch_size = 3,
                    initial_downtime_days = 0.02,
                    data_source = "external",
                    ext_path = ext_path,
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
                    run_id;
                    deadline = now() + Second(6),
                    sample_rate = 4.0,
                    seg_dur = 60.0,
                    batch_size = 3,
                    data_source = "external",
                    ext_path = ext_path,
                    instrument = vi,
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
                Receiver.generate_telemetry_masks(run_dir)
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
                    start_sim,
                    run_id;
                    sample_rate = 4.0,
                    seg_dur = 60.0,
                    batch_size = 3,
                    initial_downtime_days = 0.02,
                    data_source = "external",
                    ext_path = ext_path,
                )
            end

            clock = TelemetryCore.SimulationClock(now(), start_sim, 1800.0)
            em = Threads.@spawn with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    run_id;
                    deadline = now() + Second(6),
                    sample_rate = 4.0,
                    seg_dur = 60.0,
                    batch_size = 3,
                    data_source = "external",
                    ext_path = ext_path,
                    instrument = vi,
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
            Receiver.generate_telemetry_masks(run_dir)
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

@testset "Full-day session is always visible" begin
    model = TelemetryCore.VisibilityModel(Time(0), Second(24 * 3600), "flat")
    @test all(TelemetryCore.is_visible(model, DateTime(2035, 1, 1, h)) for h in 0:23)
    @test TelemetryCore.get_bandwidth_factor(model, DateTime(2035, 1, 1, 12)) == 1.0
    partial = TelemetryCore.VisibilityModel(Time(20), Second(8 * 3600), "flat")
    @test TelemetryCore.is_visible(partial, DateTime(2035, 1, 1, 2))
    @test !TelemetryCore.is_visible(partial, DateTime(2035, 1, 1, 12))
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
                    start_sim,
                    pace_id;
                    sample_rate = 4.0,
                    seg_dur = seg_dur,
                    batch_size = batch_size,
                    initial_downtime_days = 0.0,
                    data_source = "external",
                    ext_path = ext_path,
                )
            end
            clock = TelemetryCore.SimulationClock(now(), start_sim, speed_up)
            wall_span_ms = 4000
            deadline = clock.start_real_time + Millisecond(wall_span_ms)
            with_logger(NullLogger()) do
                Emitter.run_emitter(
                    clock,
                    link,
                    pace_id;
                    sample_rate = 4.0,
                    seg_dur = seg_dur,
                    batch_size = batch_size,
                    data_source = "external",
                    ext_path = ext_path,
                    instrument = vi,
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
            @test length(epochs) >= expected_batches - 1 # at most one batch lost to exit timing

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
            @test lags[maximum(keys(lags))] < 2 * Millisecond(period)
        finally
            rm(pace_dir; recursive = true, force = true)
        end
    end
end

@testset "Thread advisory" begin
    advisory = TelemetryCore.thread_advisory()
    if Threads.nthreads() >= 2
        @test advisory === nothing
    else
        @test advisory isa String
        @test occursin("single Julia thread", advisory)
    end
end

@testset "Batch wire format and run discovery" begin
    @test TelemetryCore.batch_name(7, true) == "LIVE_batch_7"
    @test TelemetryCore.batch_name(1200, false) == "ARCH_batch_1200"
    @test TelemetryCore.batch_id("LIVE_batch_42") == 42
    @test TelemetryCore.batch_id("ARCH_batch_9#1") == 0 # backup copy: not a batch
    @test TelemetryCore.batch_id("stray") == 0
    @test TelemetryCore.is_live_batch("LIVE_batch_3")
    @test !TelemetryCore.is_live_batch("ARCH_batch_3")
    @test TelemetryCore.is_archive_batch("ARCH_batch_3")
    @test TelemetryCore.is_batch_name("LIVE_batch_3") &&
          TelemetryCore.is_batch_name("ARCH_batch_3")
    @test !TelemetryCore.is_batch_name("events_tx.csv")

    # latest_run_id: only directories carrying a snapshot count; newest by mtime wins.
    saved_root = TelemetryCore.DATA_ROOT[]
    mktempdir() do tmp
        TelemetryCore.DATA_ROOT[] = tmp
        try
            @test TelemetryCore.latest_run_id() === nothing
            root = TelemetryCore.runs_root()
            mkpath(joinpath(root, "stray_dir")) # no snapshot: never a candidate
            for name in ("RUN_old", "RUN_new")
                mkpath(joinpath(root, name))
                touch(joinpath(root, name, "config_snapshot.toml"))
                sleep(0.05) # distinct directory mtimes
            end
            @test TelemetryCore.latest_run_id() == "RUN_new"
        finally
            TelemetryCore.DATA_ROOT[] = saved_root
        end
    end
end

@testset "Configuration accessors (single-sourced bounds)" begin
    # Defaults for an absent section, and the builders reading through the
    # same accessor the validator uses.
    tel = TelemetryCore.telemetry_settings(Dict{String,Any}())
    @test tel.session_start == Time(8) && tel.session_duration == Second(8 * 3600)
    @test tel.max_inflight_batches == 5 && tel.min_link_factor == 0.05
    vm = TelemetryCore.visibility_model(
        Dict{String,Any}(
            "telemetry" => Dict{String,Any}(
                "session_start" => "20:00:00",
                "session_duration_hours" => 6.0,
                "bandwidth_profile" => "gaussian",
                "gaussian_sigma" => 0.2,
            ),
        ),
    )
    @test vm.session_start == Time(20) &&
          vm.profile == "gaussian" &&
          vm.gaussian_sigma == 0.2
    @test_throws ArgumentError TelemetryCore.telemetry_settings(
        Dict{String,Any}("telemetry" => Dict{String,Any}("max_inflight_batches" => 0)),
    )

    loss = TelemetryCore.loss_channel_settings(Dict{String,Any}())
    @test !loss.enabled && loss.model == "bernoulli" && loss.max_retries == 3
    # A malformed-but-disabled section fails fast through every consumer.
    disabled_bad = Dict{String,Any}(
        "packet_loss" => Dict{String,Any}("enabled" => false, "p_loss_bad" => 2.0),
    )
    @test_throws ArgumentError TelemetryCore.loss_channel_settings(disabled_bad)
    @test_throws ArgumentError ChannelEffects.build_loss_model(disabled_bad, 1)
    @test_throws ArgumentError ChannelEffects.loss_retry_limit(disabled_bad)

    events = TelemetryCore.disruption_event_settings(
        Dict{String,Any}(
            "disruption" => Dict{String,Any}(
                "events" => Any[Dict{String,Any}(
                    "start_day" => 1.5,
                    "duration_hours" => 2.0,
                ),],
            ),
        ),
    )
    @test length(events) == 1 && events[1].start_day == 1.5 && events[1].severity == 1.0
    @test events[1].type == "link_disruption" && events[1].loss_multiplier == 1.0
    @test_throws ArgumentError TelemetryCore.disruption_event_settings(
        Dict{String,Any}("disruption" => Dict{String,Any}("events" => Any["not a table"])),
    )
end

@testset "Deprecated configuration keys (aliases until 1.0.0)" begin
    cfg = valid_test_cfg()
    span = pop!(cfg["simulation"], "mission_wall_seconds")
    cfg["simulation"]["test_duration_sec"] = span
    @test_logs (:warn, r"deprecated") match_mode = :any TelemetryCore.validate_config(cfg)
    @test TelemetryCore.mission_wall_seconds(cfg) == span
    @test_throws ArgumentError TelemetryCore.mission_wall_seconds(
        Dict{String,Any}("simulation" => Dict{String,Any}()),
    )
    pp = Dict{String,Any}("generate_batch_matrix" => false)
    @test TelemetryCore.aliased_value(
        pp,
        "post_processing",
        "generate_mask_timeline",
        "generate_batch_matrix",
        true,
    ) == false
    # A legacy profile column is normalized on read.
    legacy = DataFrame(SimTime = [DateTime(2035)], Ground_Archive = [3], Ground_Live = [1])
    @test hasproperty(TelemetryCore.normalize_profile!(legacy), :Ground_Total)
    @test !hasproperty(legacy, :Ground_Archive)
end

@testset "Configuration accessors: physics and supervision" begin
    phys = TelemetryCore.physics_settings(valid_test_cfg())
    @test phys.data_source == "synthetic" && phys.batch_size == 10
    @test !haskey(phys, :signal_injection_probability)
    legacy = valid_test_cfg()
    legacy["physics"]["signal_injection_probability"] = 0.02
    @test_logs (:warn, r"signal_injection_probability is deprecated") match_mode = :any TelemetryCore.physics_settings(
        legacy,
    )
    bad = valid_test_cfg()
    bad["physics"]["data_source"] = "tape"
    @test_throws ArgumentError TelemetryCore.physics_settings(bad)
    @test_throws ArgumentError TelemetryCore.physics_settings(
        Dict{String,Any}("physics" => Dict{String,Any}("sample_rate" => 4.0)),
    ) # required keys
    sup = TelemetryCore.supervision_settings(Dict{String,Any}())
    @test sup.on_component_failure == "abort" &&
          sup.max_restarts == 3 &&
          sup.watchdog_sec == 30.0
    @test_throws ArgumentError TelemetryCore.supervision_settings(
        Dict{String,Any}("supervision" => Dict{String,Any}("watchdog_sec" => 0.0)),
    )
end

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

@testset "Supervisor policies (synthetic components)" begin
    policy(p; restarts = 2, watchdog = 0.3) =
        (on_component_failure = p, max_restarts = restarts, watchdog_sec = watchdog)
    clock = TelemetryCore.SimulationClock(now(), DateTime(2035), 1.0)
    events(dir) = CSV.read(joinpath(dir, "component_events.csv"), DataFrame)
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
            orig_stdout = devnull,
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
            orig_stdout = devnull,
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
            orig_stdout = devnull,
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
            orig_stdout = devnull,
            poll_sec = 0.05,
        )
        ev = events(dir)
        @test [String(e) for e in ev[ev.Component .== "a", :Event]] == ["stalled", "recovered"]
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
        @test count(==("ingested"), rx.Event) > 50
    finally
        rm(run_dir; recursive = true, force = true)
    end
end

@testset "Alert-latency metrology (synthetic schedule)" begin
    # Four archive batches of blind-spot backlog, then two live batches;
    # realized deliveries follow the live-first / archive-newest-first
    # doctrine, the counterfactual FIFO drain re-assigns the same completions.
    mktempdir() do dir
        t0 = DateTime(2035, 1, 1, 6)
        D = Minute(3) # 3 segments × 60 s
        open(joinpath(dir, "config_snapshot.toml"), "w") do io
            write(
                io,
                """
                [simulation]
                speed_up = 60.0
                start_sim_time = "2035-01-01T06:00:00"
                mission_wall_seconds = 60.0
                [physics]
                data_source = "synthetic"
                sample_rate = 4.0
                segment_duration_sec = 60.0
                batch_size = 3
                """,
            )
        end
        epochs = Dict(
            "ARCH_batch_1" => t0 - 4D,
            "ARCH_batch_2" => t0 - 3D,
            "ARCH_batch_3" => t0 - 2D,
            "ARCH_batch_4" => t0 - D,
            "LIVE_batch_5" => t0,
            "LIVE_batch_6" => t0 + D,
        )
        for (name, epoch) in epochs
            bdir = mkpath(joinpath(dir, "ground", name))
            write(
                joinpath(bdir, "metadata.json"),
                """{"batch_id":$(TelemetryCore.batch_id(name)),"segment_count":3,"created_at":"$(epoch + D)","content_epoch":"$epoch"}""",
            )
            TelemetryCore.log_tx_event(dir, epoch + D, name, "gen")
        end
        completions = [
            ("LIVE_batch_5", t0 + Minute(4)),
            ("ARCH_batch_4", t0 + Minute(5)),
            ("ARCH_batch_3", t0 + Minute(6)),
            ("LIVE_batch_6", t0 + Minute(7)),
            ("ARCH_batch_2", t0 + Minute(8)),
            ("ARCH_batch_1", t0 + Minute(9)),
        ]
        for (name, t) in completions
            TelemetryCore.log_rx_event(dir, t, name, "ingested", 0)
        end

        schedule = Metrology.delivery_schedule(dir)
        @test [b.name for b in schedule] == ["ARCH_batch_$i" for i in 1:4] ∪ ["LIVE_batch_5", "LIVE_batch_6"]
        fifo = Dict(b.name => b.fifo_available_at for b in schedule)
        @test fifo["ARCH_batch_1"] == t0 + Minute(4) &&
              fifo["ARCH_batch_4"] == t0 + Minute(7)
        @test fifo["LIVE_batch_5"] == t0 + Minute(8) &&
              fifo["LIVE_batch_6"] == t0 + Minute(9)
        @test Metrology.batch_containing(schedule, t0 - Millisecond(1)).name ==
              "ARCH_batch_4"
        @test Metrology.batch_containing(schedule, t0 - 4D - Millisecond(1)) === nothing

        table = Metrology.alert_latency_table(dir; lookback_hours = 0.25)
        @test table.Lookback_Hours ≈ [0.0, 0.05, 0.1, 0.15, 0.2, 0.25]
        @test table.N_Alerts == fill(2, 6)
        minutes = x -> x / 60
        # Window-completeness medians over the two alerts (LIVE_5 at
        # t0 + 3 min, LIVE_6 at t0 + 6 min): realized completions 4, 5, 6, 7,
        # 8, 9 min for LIVE_5, ARCH_4, ARCH_3, LIVE_6, ARCH_2, ARCH_1; the
        # FIFO drain hands the same instants to ARCH_1 … LIVE_6 in order. The
        # window [t_m − δ, t_m) holds only the alert batch for δ ≤ D and one
        # older batch per further D.
        @test table.LIFO_Median_Hours ≈ minutes.([1.0, 1.0, 1.5, 2.0, 3.0, 4.0])
        @test table.FIFO_Median_Hours ≈ minutes.(fill(4.0, 6))
        @test issorted(table.LIFO_Median_Hours)
        @test all(table.LIFO_Q25_Hours .<= table.LIFO_Median_Hours .<= table.LIFO_Q75_Hours)

        with_logger(NullLogger()) do
            @test endswith(
                Metrology.plot_alert_latency(dir; lookback_hours = 0.25),
                "alert_latency.png",
            )
        end
        @test isfile(joinpath(dir, "alert_latency.csv"))
        @test isfile(joinpath(dir, "plots", "alert_latency.pdf"))
    end
end

# Deterministic channel for the light-time test: the first attempt on the
# named batch fails, every other transfer succeeds.
struct FirstAttemptLoss <: ChannelEffects.LossModel
    victim::String
    failed::Base.RefValue{Bool}
end
function ChannelEffects.sample_loss!(m::FirstAttemptLoss; multiplier::Float64 = 1.0)
    m.failed[] && return false
    m.failed[] = true
    return true
end

@testset "Round-trip light time defers retransmissions" begin
    tel = TelemetryCore.telemetry_settings(
        Dict{String,Any}("telemetry" => Dict{String,Any}("range_million_km" => 50.0)),
    )
    @test tel.round_trip_light_time_sec ≈ 2 * 50e9 / TelemetryCore.C_LIGHT
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

@testset "Link-rate parameterization and delivery-delay metric" begin
    base = valid_test_cfg()
    # Physical rates: one 10-minute batch at 75 kbit/s production over a
    # 230 kbit/s downlink takes 600 · 75 / 230 s; capacity 18.4 batches/h.
    rates = deepcopy(base)
    delete!(rates["telemetry"], "max_batches_per_hour")
    rates["telemetry"]["downlink_kbps"] = 230.0
    rates["telemetry"]["onboard_data_rate_kbps"] = 75.0
    tel = TelemetryCore.telemetry_settings(rates)
    @test tel.nominal_batch_transfer_sec ≈ 600 * 75 / 230
    @test tel.max_batches_per_hour ≈ 3600 / (600 * 75 / 230)
    @test tel.catch_up_ratio ≈ 230 / 75
    @test TelemetryCore.validate_config(rates) isa AbstractDict
    both = deepcopy(rates)
    both["telemetry"]["max_batches_per_hour"] = 60.0
    @test_throws ArgumentError TelemetryCore.telemetry_settings(both)
    neither = deepcopy(base)
    delete!(neither["telemetry"], "max_batches_per_hour")
    @test_throws ArgumentError TelemetryCore.validate_config(neither)
    abstraction = TelemetryCore.telemetry_settings(base)
    @test abstraction.nominal_batch_transfer_sec ≈ 180.0 &&
          isnan(abstraction.catch_up_ratio)

    # Delivery delay on a synthetic schedule: three batches, one undelivered.
    mktempdir() do dir
        t0 = DateTime(2035, 1, 1, 6)
        D = Minute(3)
        open(joinpath(dir, "config_snapshot.toml"), "w") do io
            write(
                io,
                """
                [simulation]
                speed_up = 60.0
                start_sim_time = "2035-01-01T06:00:00"
                mission_wall_seconds = 60.0
                [physics]
                data_source = "synthetic"
                sample_rate = 4.0
                segment_duration_sec = 60.0
                batch_size = 3
                """,
            )
        end
        for (name, epoch) in
            (("ARCH_batch_1", t0 - 2D), ("ARCH_batch_2", t0 - D), ("LIVE_batch_3", t0))
            bdir = mkpath(joinpath(dir, "ground", name))
            write(
                joinpath(bdir, "metadata.json"),
                """{"batch_id":$(TelemetryCore.batch_id(name)),"segment_count":3,"created_at":"$(epoch + D)","content_epoch":"$epoch"}""",
            )
            TelemetryCore.log_tx_event(dir, epoch + D, name, "gen")
        end
        # ARCH_batch_1 ends at t0 − D, so ingestion at t0 + 30 h is a 30 h + D delay.
        TelemetryCore.log_rx_event(dir, t0 + Hour(30), "ARCH_batch_1", "ingested", 0)
        TelemetryCore.log_rx_event(dir, t0 + Minute(10), "LIVE_batch_3", "ingested", 0)
        table = Metrology.delivery_delay_table(dir)
        @test table.Batch == ["ARCH_batch_1", "ARCH_batch_2", "LIVE_batch_3"]
        @test ismissing(table.Delay_Hours[2])
        @test table.Delay_Hours[1] ≈ 30 + 3 / 60
        @test table.Delay_Hours[3] ≈ 7 / 60
        summary = Metrology.delivery_compliance(table, 24.0)
        @test summary.generated == 3 && summary.delivered == 2 && summary.within == 1
        @test summary.fraction_within ≈ 1 / 3
        with_logger(NullLogger()) do
            @test endswith(
                Metrology.plot_delivery_delay(dir; requirement_hours = 24.0),
                "delivery_delay.png",
            )
        end
        @test isfile(joinpath(dir, "delivery_delay.csv"))
        @test isfile(joinpath(dir, "plots", "delivery_delay.pdf"))
    end
end

@testset "Contact schedule and low-latency periods" begin
    daily(; kwargs...) = TelemetryCore.VisibilityModel(
        Time(8),
        Second(8 * 3600),
        "flat",
        10.0,
        0.15,
        get(kwargs, :extension, Second(0)),
        365.25,
        172.0,
        get(kwargs, :exceptions, Dict{Date,Tuple{Time,Second}}()),
        get(kwargs, :schedule, TelemetryCore.ContactWindow[]),
        get(kwargs, :low_latency, TelemetryCore.ContactWindow[]),
    )

    # Seasonal extension: +4 h at the peak day of year (symmetric about the
    # window centre), none half a year away, the plain window elsewhere.
    season = daily(extension = Second(4 * 3600))
    peak = TelemetryCore.nominal_window(season, Date(2035, 6, 21))
    trough = TelemetryCore.nominal_window(season, Date(2035, 12, 21))
    @test peak.start == DateTime(2035, 6, 21, 6) && peak.stop == DateTime(2035, 6, 21, 18)
    @test (trough.stop - trough.start).value / 3.6e6 ≈ 8.0 atol = 0.02
    @test TelemetryCore.is_visible(season, DateTime(2035, 6, 21, 6, 30))
    @test !TelemetryCore.is_visible(season, DateTime(2035, 12, 21, 6, 30))
    plain = TelemetryCore.nominal_window(daily(), Date(2035, 6, 21))
    @test plain.start == DateTime(2035, 6, 21, 8) && plain.stop == DateTime(2035, 6, 21, 16)

    # Exceptions: a shortened, shifted pass and a missed pass.
    exc = daily(
        exceptions = Dict(
            Date(2035, 1, 4) => (Time(10), Second(4 * 3600)),
            Date(2035, 1, 5) => (Time(8), Second(0)),
        ),
    )
    @test TelemetryCore.is_visible(exc, DateTime(2035, 1, 4, 13))
    @test !TelemetryCore.is_visible(exc, DateTime(2035, 1, 4, 15))
    @test TelemetryCore.nominal_window(exc, Date(2035, 1, 5)) === nothing
    @test !TelemetryCore.is_visible(exc, DateTime(2035, 1, 5, 12))
    @test TelemetryCore.is_visible(exc, DateTime(2035, 1, 6, 12))
    @test length(
        TelemetryCore.contact_windows(exc, DateTime(2035, 1, 3), DateTime(2035, 1, 7)),
    ) == 3

    # Explicit schedule replaces the daily generator; passes may cross
    # midnight and the profile is evaluated within the scheduled window.
    sched = TelemetryCore.VisibilityModel(
        Time(8),
        Second(8 * 3600),
        "sine",
        10.0,
        0.15,
        Second(0),
        365.25,
        172.0,
        Dict{Date,Tuple{Time,Second}}(),
        [
            TelemetryCore.ContactWindow(DateTime(2035, 1, 2, 22), DateTime(2035, 1, 3, 4)),
            TelemetryCore.ContactWindow(DateTime(2035, 1, 4, 8), DateTime(2035, 1, 4, 14)),
        ],
        TelemetryCore.ContactWindow[],
    )
    @test TelemetryCore.is_visible(sched, DateTime(2035, 1, 3, 1))
    @test TelemetryCore.get_bandwidth_factor(sched, DateTime(2035, 1, 3, 1)) ≈ 1.0
    @test !TelemetryCore.is_visible(sched, DateTime(2035, 1, 3, 12))
    @test TelemetryCore.nominal_window(sched, Date(2035, 1, 3)) === nothing
    @test length(
        TelemetryCore.contact_windows(sched, DateTime(2035, 1, 1), DateTime(2035, 1, 10)),
    ) == 2

    # Low-latency periods: constant capacity fraction, visible outside the
    # nominal pass, transmittable for the link model.
    llp = daily(
        low_latency = [
            TelemetryCore.ContactWindow(
                DateTime(2035, 1, 5, 20),
                DateTime(2035, 1, 5, 23),
                0.5,
                true,
                "follow-up",
            ),
        ],
    )
    @test TelemetryCore.is_visible(llp, DateTime(2035, 1, 5, 21))
    @test TelemetryCore.get_bandwidth_factor(llp, DateTime(2035, 1, 5, 21)) ≈ 0.5
    @test !TelemetryCore.is_visible(llp, DateTime(2035, 1, 5, 19))
    @test ChannelEffects.is_transmittable(
        ChannelEffects.LinkModel(llp),
        DateTime(2035, 1, 5, 21),
    )
    windows = TelemetryCore.contact_windows(llp, DateTime(2035, 1, 5), DateTime(2035, 1, 6))
    @test count(w -> w.low_latency, windows) == 1 && windows[end].label == "follow-up"
    stems =
        Receiver.session_figure_stems(llp, DateTime(2035, 1, 5, 6), DateTime(2035, 1, 7, 6))
    @test first.(stems) == ["day00", "day00_low_latency", "day01"]

    # Configuration accessor: defaults, validation, CSV schedule, the
    # enabled flag, and the shipped configuration.
    base = valid_test_cfg()
    defaults = TelemetryCore.contacts_settings(base)
    @test defaults.seasonal_extension_hours == 0.0 &&
          isempty(defaults.passes) &&
          isempty(defaults.low_latency_periods) &&
          defaults.low_latency_enabled
    cfg = deepcopy(base)
    cfg["contacts"] = Dict{String,Any}(
        "seasonal_extension_hours" => 4.0,
        "exceptions" =>
            Any[Dict{String,Any}("date" => "2035-01-04", "duration_hours" => 0.0)],
        "low_latency_periods" => Any[Dict{String,Any}(
            "start" => "2035-01-02T20:00:00",
            "duration_hours" => 2.0,
            "capacity_fraction" => 0.4,
        ),],
    )
    settings = TelemetryCore.contacts_settings(cfg)
    @test haskey(settings.exceptions, Date(2035, 1, 4)) &&
          settings.exceptions[Date(2035, 1, 4)] == (Time(8), Second(0))
    @test settings.low_latency_periods[1].capacity ≈ 0.4
    model = TelemetryCore.visibility_model(cfg)
    @test TelemetryCore.get_bandwidth_factor(model, DateTime(2035, 1, 2, 21)) ≈ 0.4
    @test !TelemetryCore.is_visible(model, DateTime(2035, 1, 4, 12))
    @test TelemetryCore.validate_config(cfg) isa AbstractDict
    disabled = deepcopy(cfg)
    disabled["contacts"]["low_latency_enabled"] = false
    @test !TelemetryCore.is_visible(
        TelemetryCore.visibility_model(disabled),
        DateTime(2035, 1, 2, 21),
    )
    for (key, value) in (
        ("seasonal_extension_hours", 17.0),
        ("seasonal_extension_hours", -1.0),
        ("season_period_days", 0.0),
        ("season_peak_day_of_year", 400.0),
        ("low_latency_capacity_fraction", 0.0),
        ("low_latency_capacity_fraction", 1.5),
    )
        bad = deepcopy(base)
        bad["contacts"] = Dict{String,Any}(key => value)
        @test_throws ArgumentError TelemetryCore.contacts_settings(bad)
    end
    overlapping = deepcopy(base)
    overlapping["contacts"] = Dict{String,Any}(
        "passes" => Any[
            Dict{String,Any}("start" => "2035-01-02T08:00:00", "duration_hours" => 8.0),
            Dict{String,Any}("start" => "2035-01-02T12:00:00", "duration_hours" => 8.0),
        ],
    )
    @test_throws ArgumentError TelemetryCore.contacts_settings(overlapping)
    mixed = deepcopy(base)
    mixed["contacts"] = Dict{String,Any}(
        "passes" => Any[Dict{String,Any}(
            "start" => "2035-01-02T08:00:00",
            "duration_hours" => 8.0,
        ),],
        "exceptions" => Any[Dict{String,Any}("date" => "2035-01-04")],
    )
    @test_throws ArgumentError TelemetryCore.contacts_settings(mixed)
    mktempdir() do dir
        csv_path = joinpath(dir, "passes.csv")
        write(
            csv_path,
            "Start,DurationHours\n2035-01-03T22:00:00,6.0\n2035-01-02T08:00:00,8.0\n",
        )
        from_csv = deepcopy(base)
        from_csv["contacts"] = Dict{String,Any}("schedule_csv" => csv_path)
        passes = TelemetryCore.contacts_settings(from_csv).passes
        @test length(passes) == 2 && passes[1].start == DateTime(2035, 1, 2, 8)
        @test TelemetryCore.is_visible(
            TelemetryCore.visibility_model(from_csv),
            DateTime(2035, 1, 4, 2),
        )
        both = deepcopy(from_csv)
        both["contacts"]["passes"] =
            Any[Dict{String,Any}("start" => "2035-01-05T08:00:00", "duration_hours" => 1.0)]
        @test_throws ArgumentError TelemetryCore.contacts_settings(both)
    end
    # The default configuration (the seasonal-peak reference scenario) carries
    # one marker-triggered period on the evening of 25 June 2035.
    shipped = TelemetryCore.load_config(joinpath(dirname(@__DIR__), "config.toml"))
    @test length(TelemetryCore.contacts_settings(shipped).low_latency_periods) == 1
    @test TelemetryCore.is_visible(
        TelemetryCore.visibility_model(shipped),
        DateTime(2035, 6, 25, 21),
    )

    # Delivery-delay table: a batch ingested inside a low-latency period is
    # flagged and counted.
    mktempdir() do dir
        t0 = DateTime(2035, 1, 1, 6)
        D = Minute(3)
        open(joinpath(dir, "config_snapshot.toml"), "w") do io
            write(
                io,
                """
                [simulation]
                speed_up = 60.0
                start_sim_time = "2035-01-01T06:00:00"
                mission_wall_seconds = 60.0
                [telemetry]
                session_start = "08:00:00"
                session_duration_hours = 8.0
                [physics]
                data_source = "synthetic"
                sample_rate = 4.0
                segment_duration_sec = 60.0
                batch_size = 3
                [[contacts.low_latency_periods]]
                start = "2035-01-01T06:00:00"
                duration_hours = 1.0
                """,
            )
        end
        for (name, epoch) in (("ARCH_batch_1", t0 - D), ("LIVE_batch_2", t0))
            bdir = mkpath(joinpath(dir, "ground", name))
            write(
                joinpath(bdir, "metadata.json"),
                """{"batch_id":$(TelemetryCore.batch_id(name)),"segment_count":3,"created_at":"$(epoch + D)","content_epoch":"$epoch"}""",
            )
            TelemetryCore.log_tx_event(dir, epoch + D, name, "gen")
        end
        TelemetryCore.log_rx_event(dir, t0 + Minute(30), "LIVE_batch_2", "ingested", 0)
        TelemetryCore.log_rx_event(dir, t0 + Hour(3), "ARCH_batch_1", "ingested", 0)
        table = Metrology.delivery_delay_table(dir)
        @test table.LowLatency == [false, true]
        @test Metrology.delivery_compliance(table, 24.0).via_low_latency == 1
    end
end

@testset "Event markers and marker latency" begin
    # Accessor: sorting, defaults, validation, and the triggered period.
    base = valid_test_cfg()
    cfg = deepcopy(base)
    cfg["events"] = Dict{String,Any}(
        "markers" => Any[
            Dict{String,Any}(
                "time" => "2035-01-02T14:00:00",
                "label" => "late",
                "low_latency_after_hours" => 2.0,
                "low_latency_duration_hours" => 1.0,
                "low_latency_capacity_fraction" => 0.3,
            ),
            Dict{String,Any}("time" => "2035-01-01T09:00:00"),
        ],
    )
    markers = TelemetryCore.event_marker_settings(cfg)
    @test [m.label for m in markers] == ["marker 2", "late"]
    @test markers[1].time == DateTime(2035, 1, 1, 9) &&
          markers[1].low_latency_duration_hours == 0.0
    periods = TelemetryCore.contacts_settings(cfg).low_latency_periods
    @test length(periods) == 1 &&
          periods[1].start == DateTime(2035, 1, 2, 16) &&
          periods[1].stop == DateTime(2035, 1, 2, 17) &&
          periods[1].capacity ≈ 0.3 &&
          periods[1].label == "late"
    @test TelemetryCore.get_bandwidth_factor(
        TelemetryCore.visibility_model(cfg),
        DateTime(2035, 1, 2, 16, 30),
    ) ≈ 0.3
    @test TelemetryCore.validate_config(cfg) isa AbstractDict
    @test TelemetryCore.ground_settings(base).processing_latency_hours == 1.0
    for entry in (
        Dict{String,Any}("label" => "no time"),
        Dict{String,Any}("time" => "not a date"),
        Dict{String,Any}(
            "time" => "2035-01-01T09:00:00",
            "low_latency_after_hours" => -1.0,
        ),
        Dict{String,Any}(
            "time" => "2035-01-01T09:00:00",
            "low_latency_duration_hours" => 1.0,
            "low_latency_capacity_fraction" => 0.0,
        ),
    )
        bad = deepcopy(base)
        bad["events"] = Dict{String,Any}("markers" => Any[entry])
        @test_throws ArgumentError TelemetryCore.event_marker_settings(bad)
    end
    duplicate = deepcopy(base)
    duplicate["events"] = Dict{String,Any}(
        "markers" => Any[
            Dict{String,Any}("time" => "2035-01-01T09:00:00", "label" => "x"),
            Dict{String,Any}("time" => "2035-01-01T10:00:00", "label" => "x"),
        ],
    )
    @test_throws ArgumentError TelemetryCore.event_marker_settings(duplicate)
    negative = deepcopy(base)
    negative["ground"] = Dict{String,Any}("processing_latency_hours" => -0.5)
    @test_throws ArgumentError TelemetryCore.ground_settings(negative)
    hits = TelemetryCore.batch_markers(
        markers,
        DateTime(2035, 1, 1, 8),
        DateTime(2035, 1, 1, 9),
    )
    @test isempty(hits) # half-open span: the 09:00 marker belongs to the next batch
    @test length(
        TelemetryCore.batch_markers(
            markers,
            DateTime(2035, 1, 1, 9),
            DateTime(2035, 1, 1, 10),
        ),
    ) == 1

    # Emitter stamping during pre-population: the marker lands in the
    # metadata of the holding batch and in events_tx.csv, and the batch
    # replay treats the marker row as state-preserving.
    stamp_id = "TEST_RUN_markers_pid$(getpid())"
    stamp_dir = TelemetryCore.setup_run_dir(
        stamp_id;
        cfg = Dict{String,Any}(
            "simulation" => Dict{String,Any}(
                "speed_up" => 600.0,
                "start_sim_time" => "2035-01-01T10:00:00",
            ),
        ),
    )
    try
        start_sim = DateTime(2035, 1, 1, 10)
        marker = TelemetryCore.EventMarker(start_sim - Minute(10), "glitch")
        with_logger(NullLogger()) do
            Emitter.pre_populate(
                start_sim,
                stamp_id;
                sample_rate = 4.0,
                seg_dur = 60.0,
                batch_size = 3,
                initial_downtime_days = 0.01,
                markers = [marker],
            )
        end
        # Batches span 3 min from 10:00 − 14.4 min: the second one holds −10 min.
        meta = TelemetryCore.read_batch_metadata(
            joinpath(stamp_dir, "onboard", "ARCH_batch_2"),
        )
        @test meta["markers"] == ["glitch"]
        @test !haskey(
            TelemetryCore.read_batch_metadata(
                joinpath(stamp_dir, "onboard", "ARCH_batch_1"),
            ),
            "markers",
        )
        tx = CSV.read(joinpath(stamp_dir, "events_tx.csv"), DataFrame)
        marker_rows = tx[tx.Event .== "marker", :]
        @test nrow(marker_rows) == 1 &&
              String(marker_rows.Batch[1]) == "ARCH_batch_2" &&
              DateTime(marker_rows.SimTime[1]) == marker.time
        @test TelemetryCore.max_logged_batch_id(stamp_dir) == 5 # 15 segments of 60 s in 0.01 d
        TelemetryCore.save_markers(stamp_dir, [marker])
        loaded = TelemetryCore.load_markers(stamp_dir)
        @test length(loaded) == 1 &&
              loaded[1].label == "glitch" &&
              loaded[1].time == marker.time
        @test isempty(TelemetryCore.load_markers(mktempdir()))
        # No rx events: every batch stays onboard through the replay.
        states = with_logger(NullLogger()) do
            Receiver.reconstruct_batch_states(
                stamp_dir,
                DataFrame(SimTime = [start_sim + Minute(1)]),
            )
        end
        @test length(states) == 1 && length(states[1].onboard_archive) == 5
    finally
        rm(stamp_dir; recursive = true, force = true)
    end

    # Marker latency on the synthetic schedule of the alert-latency test:
    # a marker inside LIVE_batch_5 counts from its own instant, a marker
    # before the first batch yields a missing row.
    mktempdir() do dir
        t0 = DateTime(2035, 1, 1, 6)
        D = Minute(3)
        open(joinpath(dir, "config_snapshot.toml"), "w") do io
            write(
                io,
                """
                [simulation]
                speed_up = 60.0
                start_sim_time = "2035-01-01T06:00:00"
                mission_wall_seconds = 60.0
                [physics]
                data_source = "synthetic"
                sample_rate = 4.0
                segment_duration_sec = 60.0
                batch_size = 3
                """,
            )
        end
        epochs =
            Dict("ARCH_batch_1" => t0 - 2D, "ARCH_batch_2" => t0 - D, "LIVE_batch_3" => t0)
        for (name, epoch) in epochs
            bdir = mkpath(joinpath(dir, "ground", name))
            write(
                joinpath(bdir, "metadata.json"),
                """{"batch_id":$(TelemetryCore.batch_id(name)),"segment_count":3,"created_at":"$(epoch + D)","content_epoch":"$epoch"}""",
            )
            TelemetryCore.log_tx_event(dir, epoch + D, name, "gen")
        end
        for (name, t) in (
            ("LIVE_batch_3", t0 + Minute(4)),
            ("ARCH_batch_2", t0 + Minute(5)),
            ("ARCH_batch_1", t0 + Minute(6)),
        )
            TelemetryCore.log_rx_event(dir, t, name, "ingested", 0)
        end
        TelemetryCore.save_markers(
            dir,
            [
                TelemetryCore.EventMarker(t0 + Minute(1), "inside"),
                TelemetryCore.EventMarker(t0 - Hour(1), "before"),
            ],
        )
        table = Metrology.marker_latency_table(dir; lookback_hours = 0.1)
        inside = table[table.Label .== "inside", :]
        # δ = 0 and D: the alert batch alone (4 min − 1 min), then ARCH_2
        # (5 min − 1 min); the FIFO drain hands 4, 5, 6 min to ARCH_1,
        # ARCH_2, LIVE_3 in order.
        @test inside.Batch == fill("LIVE_batch_3", 3)
        @test inside.Lookback_Hours ≈ [0.0, 0.05, 0.1]
        @test collect(inside.LIFO_Hours) ≈ [3.0, 4.0, 5.0] ./ 60
        @test collect(inside.FIFO_Hours) ≈ [5.0, 5.0, 5.0] ./ 60
        before = table[table.Label .== "before", :]
        @test nrow(before) == 1 && before.Batch[1] == "" && ismissing(before.LIFO_Hours[1])
        with_logger(NullLogger()) do
            @test endswith(
                Metrology.plot_alert_latency(
                    dir;
                    lookback_hours = 0.1,
                    processing_latency_hours = 0.5,
                ),
                "alert_latency.png",
            )
        end
        @test isfile(joinpath(dir, "alert_latency_markers.csv"))
    end
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
    @test TelemetryCore.onboard_capacity(rates).gigabit ≈ 14 * 86_400 * 75 / 1e6
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
                start,
                gap_id;
                sample_rate = 4.0,
                seg_dur = 60.0,
                batch_size = 3,
                initial_downtime_days = 0.01,
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
                start,
                rec_id;
                sample_rate = 4.0,
                seg_dur = 60.0,
                batch_size = 3,
                initial_downtime_days = 0.01,
                onboard_capacity_batches = 2,
            )
        end
        @test TelemetryCore.max_logged_batch_id(rec_dir) == 2
        tx = CSV.read(joinpath(rec_dir, "events_tx.csv"), DataFrame)
        rec_rows = tx[tx.Batch .== "RECORDER", :]
        @test String.(rec_rows.Event) == ["gap_start"]
        @test DateTime(rec_rows.SimTime[1]) == start - Minute(8) - Second(24)
        @test TelemetryCore.open_recorder_gap(rec_dir)
        @test Receiver.generation_gap_spans(rec_dir, start - Hour(1), 5.0, "RECORDER") ==
              [(1 - 8.4 / 60, 5.0)]
        @test isempty(Receiver.generation_gap_spans(rec_dir, start, 5.0, "SCHEDULED"))
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
                live_id;
                deadline = now() + Second(3),
                sample_rate = 4.0,
                seg_dur = 60.0,
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

@testset "HDF5 product export" begin
    HDF5 = DeepSpaceTelemetry.Export.HDF5
    mktempdir() do dir
        t0 = DateTime(2035, 1, 1, 6)
        D = Minute(3)
        open(joinpath(dir, "config_snapshot.toml"), "w") do io
            write(
                io,
                """
                [simulation]
                speed_up = 60.0
                start_sim_time = "2035-01-01T06:00:00"
                mission_wall_seconds = 60.0
                [physics]
                data_source = "synthetic"
                sample_rate = 4.0
                segment_duration_sec = 60.0
                batch_size = 3
                [provenance.platform]
                hostname = "testhost"
                git_commit = "abc123"
                """,
            )
        end
        for (name, epoch) in (("ARCH_batch_1", t0 - D), ("LIVE_batch_2", t0))
            TelemetryCore.log_tx_event(dir, epoch + D, name, "gen")
        end
        TelemetryCore.log_rx_event(dir, t0 + Minute(5), "LIVE_batch_2", "ingested", 0)
        TelemetryCore.save_markers(
            dir,
            [TelemetryCore.EventMarker(t0 + Minute(1), "glitch")],
        )
        mkpath(joinpath(dir, "masks"))
        write(
            joinpath(dir, "mission_profile.csv"),
            "SimTime,WallTime,Mission_Day,Hours_Elapsed,Bandwidth_Pct,Onboard_Buffer,Link_Buffer,Ground_Total,Ground_Live,Ground_Arch,Nominal_Bandwidth_Pct,Lost_Count,Retry_Count,Disruption_Active\n" *
            "2035-01-01T06:00:00,2026-01-01T00:00:00,0.0,0.0,50.0,2,0,0,0,0,50.0,0,0,false\n" *
            "2035-01-01T06:06:00,2026-01-01T00:00:06,0.0,0.1,60.0,1,0,1,1,0,60.0,0,0,true\n",
        )
        write(
            joinpath(dir, "masks", "telemetry_mask_timeline.csv"),
            "SimTime,Batch_1,Batch_2\n2035-01-01T06:00:00,1,1\n2035-01-01T06:06:00,1,3\n",
        )
        write(
            joinpath(dir, "masks", "pointwise_mask_final.csv"),
            "Time_Index,Ground_Available\n1,0\n2,0\n3,1\n",
        )
        path = with_logger(NullLogger()) do
            DeepSpaceTelemetry.Export.export_hdf5(dir)
        end
        @test path == joinpath(dir, "products.h5") && isfile(path)
        HDF5.h5open(path, "r") do f
            @test HDF5.read_attribute(f, "format_version") == "1"
            @test HDF5.read_attribute(f, "run_id") == basename(dir)
            @test HDF5.read_attribute(f, "hostname") == "testhost"
            @test HDF5.read_attribute(f, "git_commit") == "abc123"
            @test HDF5.read_attribute(f, "speed_up") == 60.0
            @test occursin("speed_up = 60.0", HDF5.read_attribute(f, "config_snapshot"))
            @test read(f["events/tx/Event"]) == ["gen", "gen"]
            @test read(f["events/tx/SimTime"]) ≈ [0.0, 180.0]
            @test read(f["events/tx/SimTime_iso"]) ==
                  ["2035-01-01T06:00:00", "2035-01-01T06:03:00"]
            @test HDF5.read_attribute(f["events/tx"], "rows") == 2
            @test read(f["events/rx/Attempt"]) == [0]
            @test read(f["markers/Label"]) == ["glitch"]
            @test read(f["metrics/mission_profile/Onboard_Buffer"]) == [2, 1]
            @test read(f["metrics/mission_profile/Disruption_Active"]) == UInt8[0, 1]
            states = read(f["masks/timeline/states"])
            @test size(states) == (2, 2) && states[2, 2] == 3 # Julia reads (batch, snapshot)
            @test read(f["masks/timeline/batch_id"]) == [1, 2]
            @test read(f["masks/timeline/SimTime"]) ≈ [0.0, 360.0]
            @test read(f["masks/pointwise/pointwise_mask_final/Ground_Available"]) ==
                  Int8[0, 0, 1]
            @test !haskey(f, "metrology/delivery_delay")
        end
        with_logger(NullLogger()) do
            DeepSpaceTelemetry.Export.export_hdf5(dir)
        end
        @test isfile(joinpath(dir, "products#1.h5"))
    end
    @test_throws ArgumentError DeepSpaceTelemetry.Export.export_hdf5(
        joinpath(mktempdir(), "absent"),
    )
    cfg = valid_test_cfg()
    cfg["post_processing"] = Dict{String,Any}("hdf5_export" => "yes")
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    cfg["post_processing"]["hdf5_export"] = true
    @test TelemetryCore.estimate_artifacts(cfg).hdf5_bytes > 0
    @test TelemetryCore.estimate_artifacts(valid_test_cfg()).hdf5_bytes == 0
    @test !isempty(TelemetryCore.platform_provenance()["package_version"])
end

@testset "Publication figure export" begin
    full = PlotTheme.PlotStyle()
    @test full.scale == 1.0 && full.size_summary == PlotTheme.FIG_SIZE_SUMMARY
    @test full.fontsize == 12.0 && full.linewidth == PlotTheme.LINEWIDTH_DATA
    single = PlotTheme.style_for_width(86.0)
    @test 0.47 < single.scale < 0.49
    @test single.size_summary[1] == round(Int, 673 * single.scale)
    @test single.size_summary[2] > single.scale * PlotTheme.FIG_SIZE_SUMMARY[2] # extra height
    @test single.fontsize ≈ 12 * 0.85 && single.fontsize_annotation ≈ 9.4
    @test PlotTheme.style_for_width(178.0).scale ≈ 1.0 atol = 0.01
    @test_throws ArgumentError PlotTheme.PlotStyle(0.0)

    base = valid_test_cfg()
    @test !TelemetryCore.publication_settings(base).enabled
    cfg = deepcopy(base)
    cfg["post_processing"] = Dict{String,Any}(
        "publication" => Dict{String,Any}(
            "enabled" => true,
            "format" => "svg",
            "column_width_mm" => 86.0,
        ),
    )
    settings = TelemetryCore.publication_settings(cfg)
    @test settings.enabled && settings.format == "svg" && settings.column_width_mm == 86.0
    @test TelemetryCore.validate_config(cfg) isa AbstractDict
    for (key, value) in (("format", "eps"), ("column_width_mm", 10.0), ("enabled", "yes"))
        bad = deepcopy(base)
        bad["post_processing"] =
            Dict{String,Any}("publication" => Dict{String,Any}(key => value))
        @test_throws ArgumentError TelemetryCore.publication_settings(bad)
    end

    # A synthetic run with a metrics profile and delivered batches: the
    # summary and the two metrology figures export at single-column width
    # as SVG with the run-ID suffix and a provenance sidecar; the run's
    # metrology tables are left untouched.
    mktempdir() do dir
        t0 = DateTime(2035, 1, 1, 6)
        D = Minute(3)
        open(joinpath(dir, "config_snapshot.toml"), "w") do io
            write(
                io,
                """
                [simulation]
                speed_up = 60.0
                start_sim_time = "2035-01-01T06:00:00"
                mission_wall_seconds = 60.0
                [telemetry]
                session_start = "08:00:00"
                session_duration_hours = 8.0
                max_batches_per_hour = 20.0
                [physics]
                data_source = "synthetic"
                sample_rate = 4.0
                segment_duration_sec = 60.0
                batch_size = 3
                [provenance.platform]
                package_version = "0.9.0"
                git_commit = "abc123"
                """,
            )
        end
        for (name, epoch) in (("ARCH_batch_1", t0 - D), ("LIVE_batch_2", t0))
            bdir = mkpath(joinpath(dir, "ground", name))
            write(
                joinpath(bdir, "metadata.json"),
                """{"batch_id":$(TelemetryCore.batch_id(name)),"segment_count":3,"created_at":"$(epoch + D)","content_epoch":"$epoch"}""",
            )
            TelemetryCore.log_tx_event(dir, epoch + D, name, "gen")
        end
        TelemetryCore.log_rx_event(dir, t0 + Minute(5), "LIVE_batch_2", "ingested", 0)
        TelemetryCore.log_rx_event(dir, t0 + Minute(6), "ARCH_batch_1", "ingested", 0)
        write(
            joinpath(dir, "mission_profile.csv"),
            "SimTime,WallTime,Mission_Day,Hours_Elapsed,Bandwidth_Pct,Onboard_Buffer,Link_Buffer,Ground_Total,Ground_Live,Ground_Arch,Nominal_Bandwidth_Pct,Lost_Count,Retry_Count,Disruption_Active\n" *
            "2035-01-01T06:00:00,2026-01-01T00:00:00,0.0,0.0,50.0,2,0,0,0,0,50.0,0,0,false\n" *
            "2035-01-01T06:06:00,2026-01-01T00:00:06,0.0,0.1,60.0,0,0,2,1,1,60.0,0,0,false\n",
        )
        paths = with_logger(NullLogger()) do
            DeepSpaceTelemetry.Publication.export_publication_figures(
                dir;
                format = "svg",
                column_width_mm = 86.0,
            )
        end
        run_id = basename(dir)
        @test sort(basename.(paths)) == sort([
            "mission_summary_global__$run_id.svg",
            "alert_latency__$run_id.svg",
            "delivery_delay__$run_id.svg",
        ])
        @test all(isfile, paths) && all(startswith(joinpath(dir, "publication")), paths)
        @test !isfile(joinpath(dir, "alert_latency.csv"))
        @test !isfile(joinpath(dir, "delivery_delay.csv"))
        record = TOML.parsefile(joinpath(dir, "publication", "PROVENANCE.toml"))["export"]
        @test record["run_id"] == run_id &&
              record["git_commit"] == "abc123" &&
              record["column_width_mm"] == 86.0 &&
              record["format"] == "svg" &&
              length(record["figures"]) == 3 &&
              length(record["config_snapshot_sha256"]) == 64
        @test_throws ArgumentError DeepSpaceTelemetry.Publication.export_publication_figures(
            dir;
            format = "eps",
        )
    end
end
