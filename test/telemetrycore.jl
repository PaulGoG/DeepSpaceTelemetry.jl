# TelemetryCore: clock and visibility models, configuration validation and accessors, storage governance, batch I/O.

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

@testset "Storage safety (budget gate)" begin
    cfg_oversized = Dict(
        "simulation" => Dict("speed_up" => 1.0, "mission_wall_seconds" => 1000000.0),
        "storage" => Dict("max_storage_gb" => 0.0001),
        "physics" => Dict(
            "segment_duration_sec" => 60.0,
            "sample_rate" => 1024.0,
            "batch_size" => 15,
        ),
    )
    @test_throws TelemetryCore.StorageBudgetError TelemetryCore.check_storage_limits(
        cfg_oversized,
    )
    @test TelemetryCore.storage_budget(cfg_oversized).max_gb == 0.0001

    cfg_safe = Dict(
        "simulation" => Dict("speed_up" => 1.0, "mission_wall_seconds" => 100.0),
        "storage" => Dict("max_storage_gb" => 10.0),
        "physics" => Dict(
            "segment_duration_sec" => 60.0,
            "sample_rate" => 1024.0,
            "batch_size" => 15,
        ),
    )
    @test TelemetryCore.check_storage_limits(cfg_safe) === nothing
    # Without the key the default budget applies; the retired simulation key
    # is rejected rather than read.
    @test TelemetryCore.storage_budget(Dict{String,Any}()).max_gb == 5.0
    @test_throws ArgumentError TelemetryCore.storage_budget(
        Dict{String,Any}("simulation" => Dict{String,Any}("max_storage_gb" => 1.0)),
    )
end

@testset "Config validation: hard errors" begin
    @test TelemetryCore.validate_config(valid_test_cfg()) isa AbstractDict

    broken = [
        ("simulation", "speed_up", 0.0),
        ("simulation", "mission_wall_seconds", -1.0),
        ("simulation", "initial_downtime_days", -0.5),
        ("storage", "max_storage_gb", 0.0),
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

    # A sample period longer than the segment: less than one sample per segment
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

    # the retired [disaster] section name is rejected outright
    cfg = valid_test_cfg()
    cfg["disaster"] = Dict{String,Any}("events" => [Dict("start_day" => -1.0)])
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)

    # a malformed [packet_loss] section is rejected even while disabled:
    # types, enumerations, and bounds must fail fast, never lie dormant
    cfg = valid_test_cfg()
    cfg["packet_loss"] =
        Dict{String,Any}("enabled" => false, "model" => "unsupported_model")
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)

    # an unknown capacity profile is rejected by the accessor and by the model
    cfg = valid_test_cfg()
    cfg["telemetry"]["bandwidth_profile"] = "trapezoid"
    @test_throws r"telemetry\.bandwidth_profile" TelemetryCore.validate_config(cfg)
    @test_throws ArgumentError TelemetryCore.VisibilityModel(
        Time(8),
        Second(8 * 3600),
        "trapezoid",
    )

    # [[labels]] corner cases: rows below 1, a missing bound, an entry that is
    # not a table, a non-integer row
    for labels in (
        Any[Dict{String,Any}(
            "label" => "x",
            "label_start_index" => 0,
            "label_end_index" => 3,
        )],
        Any[Dict{String,Any}("label" => "x", "label_start_index" => 1)],
        Any["not a table"],
        Any[Dict{String,Any}(
            "label" => "x",
            "label_start_index" => 2.5,
            "label_end_index" => 3,
        )],
    )
        cfg = valid_test_cfg()
        cfg["labels"] = labels
        @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    end

    # external_data_columns: external source only; a list of unique, non-empty
    # names, each present in the file's header.
    cfg = valid_test_cfg()
    cfg["physics"]["external_data_columns"] = ["A"]
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    mktempdir() do tmp
        path = joinpath(tmp, "two_columns.csv")
        CSV.write(path, DataFrame(A = Float32[1, 2], E = Float32[3, 4]))
        for columns in (["A", "Q"], ["A", "A"], ["A", ""], "A", [1])
            cfg = valid_test_cfg()
            cfg["physics"]["data_source"] = "external"
            cfg["physics"]["external_data_path"] = path
            cfg["physics"]["external_data_columns"] = columns
            @test_throws ArgumentError TelemetryCore.validate_config(cfg)
        end
        cfg = valid_test_cfg()
        cfg["physics"]["data_source"] = "external"
        cfg["physics"]["external_data_path"] = path
        cfg["physics"]["external_data_columns"] = ["E", "A"]
        @test (TelemetryCore.validate_config(cfg); true)
        @test TelemetryCore.physics_settings(cfg).external_data_columns == ["E", "A"]
        @test TelemetryCore.csv_header(path) == ["A", "E"]
    end
end

@testset "Config validation: warnings" begin
    # Emitter pacing: 60 s segments at 10^6× → 0.06 ms real period
    cfg = valid_test_cfg()
    cfg["simulation"]["speed_up"] = 1.0e6
    @test_logs (:warn, r"cannot keep pace") match_mode=:any TelemetryCore.validate_config(
        cfg,
    )

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
    cfg = valid_test_cfg()
    cfg["labels"] = Any[Dict{String,Any}(
        "label" => "x",
        "label_start_index" => 1,
        "label_end_index" => 2,
        "colour" => 1,
    )] # unknown label key
    @test_logs (:warn, r"Unrecognized key labels\[1\]\.colour") match_mode = :any TelemetryCore.validate_config(
        cfg,
    )
    # The [payload] section is free-form, like [provenance]: no warning.
    cfg = valid_test_cfg()
    cfg["payload"] = Dict{String,Any}("source" => "exporter", "n_rows" => 10)
    logs, _ = Test.collect_test_logs(() -> TelemetryCore.validate_config(cfg))
    @test !any(l -> occursin("Unrecognized section", string(l.message)), logs)
    @test !any(l -> occursin("payload", string(l.message)), logs)

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
        @test_throws ArgumentError TelemetryCore.setup_run_dir(reuse_id)
        # Platform provenance is stamped into every snapshot
        snap = TOML.parsefile(joinpath(run_dir, "config_snapshot.toml"))
        @test haskey(snap, "provenance") && haskey(snap["provenance"], "platform")
        @test haskey(snap["provenance"]["platform"], "hostname")
        @test snap["provenance"]["platform"]["julia_version"] == string(VERSION)
        @test snap["provenance"]["config_sha256"] == TelemetryCore.config_sha256(snap)
    finally
        rm(run_dir; recursive = true, force = true)
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
    # Each payload column adds one full column of samples.
    base["physics"]["external_data_columns"] = ["A", "E", "T"]
    est3 = TelemetryCore.estimate_artifacts(base)
    @test est3.n_columns == 3
    @test est3.payload_bytes ≈ 3 * 200 * 15.0 rtol = 1e-12
    delete!(base["physics"], "external_data_columns")
    @test TelemetryCore.estimate_artifacts(base).n_columns == 1
    @test est.prunable_bytes == est.payload_bytes
    @test est.mask_bytes == 0.0
    @test est.pointwise_bytes == 0.0
    @test est.file_count > 0

    # Calibration override propagates
    base["storage"]["bytes_per_sample"] = 30.0
    @test TelemetryCore.estimate_artifacts(base).payload_bytes ≈ 200 * 30.0 rtol = 1e-12
    delete!(base["storage"], "bytes_per_sample")

    # The synthetic flag series is sized by its own calibration key
    base["physics"]["data_source"] = "synthetic"
    @test TelemetryCore.estimate_artifacts(base).payload_bytes ≈ 200 * 4.0 rtol = 1e-12
    base["storage"]["bytes_per_flag_sample"] = 8.0
    @test TelemetryCore.estimate_artifacts(base).payload_bytes ≈ 200 * 8.0 rtol = 1e-12
    delete!(base["storage"], "bytes_per_flag_sample")
    delete!(base["physics"], "data_source")

    # Gate matrix — under budget, retention off: pass
    @test TelemetryCore.check_storage_limits(deepcopy(base)) === nothing

    # Over budget, retention off: hard stop
    over = deepcopy(base)
    over["storage"]["max_storage_gb"] = 1.0e-8
    @test_throws TelemetryCore.StorageBudgetError TelemetryCore.check_storage_limits(over)

    # Over budget, retention on, steady state also over: hard stop
    over_steady = deepcopy(over)
    over_steady["retention"] =
        Dict{String,Any}("enabled" => true, "high_watermark_gb" => 1.0e-9)
    @test_throws TelemetryCore.StorageBudgetError TelemetryCore.check_storage_limits(
        over_steady,
    )

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
    @test_throws TelemetryCore.StorageBudgetError TelemetryCore.check_storage_limits(
        over_files,
    )

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
    # does not run from the package root)
    @test TelemetryCore.load_config("config.toml") isa AbstractDict

    # Malformed TOML: hard stop for the live config and for a run snapshot;
    # a run without its own snapshot is refused, not read through config.toml
    mktempdir() do dir
        bad_toml = joinpath(dir, "config.toml")
        write(bad_toml, "[simulation\nspeed_up = ")
        @test_throws ArgumentError TelemetryCore.load_config(bad_toml)

        run_dir = joinpath(dir, "run")
        mkpath(run_dir)
        write(joinpath(run_dir, "config_snapshot.toml"), "[simulation\nspeed_up = ")
        @test_throws ArgumentError TelemetryCore.load_run_config(run_dir)
        err = try
            TelemetryCore.load_run_config(run_dir)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("config_snapshot.toml", err.msg)
        rm(joinpath(run_dir, "config_snapshot.toml"))
        @test_throws ArgumentError TelemetryCore.load_run_config(run_dir)
        write(joinpath(run_dir, "config_snapshot.toml"), "[simulation]\nspeed_up = 5.0\n")
        cfg_snap, source = TelemetryCore.load_run_config_with_source(run_dir)
        @test source == "snapshot" && cfg_snap["simulation"]["speed_up"] == 5.0
        # Mask-timeline readers: single-task table and header-less line count.
        mkpath(joinpath(run_dir, "masks"))
        write(
            TelemetryCore.mask_timeline_path(run_dir),
            "SimTime,Batch_1,Batch_2\n2030-01-01T00:00:00,1,0\n2030-01-01T01:00:00,3,1\n",
        )
        @test TelemetryCore.mask_timeline_rows(run_dir) == 2
        @test nrow(TelemetryCore.read_mask_timeline(run_dir)) == 2
    end
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
        @test vec(loaded_seg.data) == Float32[1.0, 2.0, 3.0] &&
              loaded_seg.columns == ["Amplitude"]

        # Several payload columns: one file column per payload column under its name; the vector form is one Amplitude column.
        wide = TelemetryCore.DataSegment(
            3,
            DateTime(2030, 1, 1, 0, 2),
            Float32[1 10; 2 20; 3 30],
            ["A", "E"],
        )
        @test wide.columns == ["A", "E"] && size(wide.data) == (3, 2)
        @test TelemetryCore.segment_column(wide, "E") == Float32[10, 20, 30]
        @test TelemetryCore.segment_column(wide, 1) == Float32[1, 2, 3]
        @test_throws ArgumentError TelemetryCore.segment_column(wide, "T")
        @test_throws ArgumentError TelemetryCore.segment_column(wide, 3)
        @test_throws DimensionMismatch TelemetryCore.DataSegment(
            4,
            DateTime(2030),
            Float32[1 2; 3 4],
            ["A"],
        )
        @test_throws ArgumentError TelemetryCore.DataSegment(
            4,
            DateTime(2030),
            Matrix{Float32}(undef, 2, 0),
            String[],
        )
        wide_path = joinpath(tmp, "seg_3.csv")
        TelemetryCore.save_segment(wide_path, wide)
        @test readline(wide_path) == "A,E"
        back = TelemetryCore.load_segment(wide_path)
        @test back.id == 3 && back.columns == ["A", "E"] && back.data == wide.data
        @test seg1.columns == ["Amplitude"] && size(seg1.data) == (3, 1)
        @test readline(joinpath(batch_dir, "seg_1.csv")) == "Amplitude"
        # A one-column file of an earlier release reads and rewrites byte for byte.
        legacy = joinpath(tmp, "seg_9.csv")
        write(legacy, "Amplitude\n0.0\n1.0\n8.2780985e-5\n")
        TelemetryCore.save_segment(
            joinpath(tmp, "seg_9_copy.csv"),
            TelemetryCore.load_segment(legacy),
        )
        @test read(legacy) == read(joinpath(tmp, "seg_9_copy.csv"))
        text_path = joinpath(tmp, "seg_8.csv")
        write(text_path, "A,B\n1.0,x\n")
        @test_throws ArgumentError TelemetryCore.load_segment(text_path)
        # A corrupt metadata.json is an error; a directory without one is not a batch.
        corrupt = mkpath(joinpath(tmp, "batch_101"))
        write(joinpath(corrupt, "metadata.json"), "{not json")
        @test_throws ArgumentError TelemetryCore.read_batch_metadata(corrupt)
        bare = mkpath(joinpath(tmp, "batch_102"))
        @test TelemetryCore.read_batch_metadata(bare) == Dict{String,Any}()
    end
end

@testset "Retired configuration keys (2.0.0)" begin
    for (section, key, value) in (
        ("physics", "confusion_observation_years", 1.0),
        ("physics", "noise_f_min_hz", 1.0e-5),
        ("post_processing", "payload_spectrum", true),
    )
        cfg = valid_test_cfg()
        get!(cfg, section, Dict{String,Any}())[key] = value
        err = try
            TelemetryCore.validate_config(cfg)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("removed at 2.0.0", sprint(showerror, err))
        # The snapshot of a run made before the removal still reads.
        section == "physics" && @test TelemetryCore.physics_settings(cfg).sample_rate > 0
    end

    cfg = valid_test_cfg()
    cfg["physics"]["segment_duration_sec"] = 0.0005
    @test_throws ArgumentError TelemetryCore.physics_settings(cfg)

    # A fractional rotation limit gives a whole byte count.
    cfg = valid_test_cfg()
    cfg["retention"] = Dict{String,Any}("log_rotate_mb" => 0.3)
    @test TelemetryCore.retention_settings(cfg).log_rotate_bytes == round(Int, 0.3 * 1024^2)
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
    @test TelemetryCore.get_bandwidth_factor(m, DateTime(2030, 1, 2, 2, 0, 0)) ≈ 1.0 rtol =
        1e-12
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
        @test TelemetryCore.read_table(p).a == [3]
        @test TelemetryCore.read_table(joinpath(tmp, "res#1.csv")).a == [1]
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

@testset "Retired configuration aliases (1.0.0)" begin
    # Every retired key is rejected with the replacement named, in the accessor
    # and in the validator; the current keys pass untouched.
    message_of(f) =
        try
            f()
            ""
        catch e
            sprint(showerror, e)
        end
    cfg = valid_test_cfg()
    span = pop!(cfg["simulation"], "mission_wall_seconds")
    cfg["simulation"]["test_duration_sec"] = span
    @test occursin(
        "simulation.mission_wall_seconds",
        message_of(() -> TelemetryCore.mission_wall_seconds(cfg)),
    )
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    @test_throws ArgumentError TelemetryCore.mission_wall_seconds(
        Dict{String,Any}("simulation" => Dict{String,Any}()),
    )
    cfg = valid_test_cfg()
    cfg["simulation"]["max_storage_gb"] = 1.0
    @test occursin(
        "storage.max_storage_gb",
        message_of(() -> TelemetryCore.storage_budget(cfg)),
    )
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    cfg = valid_test_cfg()
    cfg["post_processing"] = Dict{String,Any}("generate_batch_matrix" => false)
    @test occursin(
        "post_processing.generate_mask_timeline",
        message_of(() -> TelemetryCore.estimate_artifacts(cfg)),
    )
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    cfg = valid_test_cfg()
    cfg["disaster"] = Dict{String,Any}("events" => Any[])
    @test occursin(
        "[disruption]",
        message_of(() -> TelemetryCore.disruption_event_settings(cfg)),
    )
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    @test TelemetryCore.reject_removed_key(
        Dict{String,Any}(),
        "simulation",
        "test_duration_sec",
    ) === nothing
    @test TelemetryCore.validate_config(valid_test_cfg()) isa AbstractDict
    # A legacy profile column is a data artifact, not a configuration alias,
    # and is still normalized on read.
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
    @test_throws ArgumentError TelemetryCore.physics_settings(legacy)
    bad = valid_test_cfg()
    bad["physics"]["data_source"] = "tape"
    @test_throws ArgumentError TelemetryCore.physics_settings(bad)
    @test_throws ArgumentError TelemetryCore.physics_settings(
        Dict{String,Any}("physics" => Dict{String,Any}("sample_rate" => 4.0)),
    ) # required keys
    geometry = (sample_rate = 0.3, segment_duration_sec = 5.0, batch_size = 10)
    @test TelemetryCore.samples_per_segment(0.3, 5.0) == 2
    @test TelemetryCore.points_per_batch(geometry) == 20
    @test_throws ArgumentError TelemetryCore.samples_per_segment(0.1, 5.0)
    sup = TelemetryCore.supervision_settings(Dict{String,Any}())
    @test sup.on_component_failure == "abort" &&
          sup.max_restarts == 3 &&
          sup.watchdog_sec == 30.0
    @test_throws ArgumentError TelemetryCore.supervision_settings(
        Dict{String,Any}("supervision" => Dict{String,Any}("watchdog_sec" => 0.0)),
    )
end

@testset "Configuration accessors: label spans and the payload grid" begin
    # [[labels]] entries come back in file order with a default label; an
    # empty span (start > end) is returned as declared.
    cfg = valid_test_cfg()
    cfg["labels"] = Any[
        Dict{String,Any}(
            "label" => "mbhb_1",
            "label_start_index" => 100,
            "label_end_index" => 2500,
        ),
        Dict{String,Any}("label_start_index" => 50, "label_end_index" => 10),
    ]
    spans = TelemetryCore.label_settings(cfg)
    @test spans isa Vector{TelemetryCore.LabelSpan} && length(spans) == 2
    @test spans[1] == TelemetryCore.LabelSpan("mbhb_1", 100, 2500)
    @test spans[2].label == "label 2"
    @test spans[2].row_first > spans[2].row_last
    @test isempty(TelemetryCore.label_settings(valid_test_cfg()))

    # Row 1 sits at the origin; 4 Hz puts row 17281 at origin + 4320 s.
    origin = DateTime(2035, 1, 1, 4, 48)
    fs = 4.0
    @test TelemetryCore.payload_row_time(origin, fs, 1) == origin
    @test TelemetryCore.payload_row_time(origin, fs, 17281) == DateTime(2035, 1, 1, 6)
    @test TelemetryCore.payload_time_row(origin, fs, DateTime(2035, 1, 1, 6)) == 17281
    @test TelemetryCore.payload_time_row(
        origin,
        fs,
        TelemetryCore.payload_row_time(origin, fs, 4801),
    ) == 4801
    @test TelemetryCore.mission_epoch(valid_test_cfg()) == DateTime(2035, 1, 1, 6)
    downtime = valid_test_cfg()
    downtime["simulation"]["initial_downtime_days"] = 0.05
    @test TelemetryCore.payload_origin(downtime) ==
          DateTime(2035, 1, 1, 6) - Hour(1) - Minute(12)
    downtime["provenance"] = Dict{String,Any}("payload_origin" => "2035-01-01T03:00:00")
    @test TelemetryCore.payload_origin(downtime) == DateTime(2035, 1, 1, 3)
    # 10 s × 3600 → 10 mission hours after the epoch
    @test TelemetryCore.mission_end(valid_test_cfg()) == DateTime(2035, 1, 1, 16)
end

@testset "Configuration accessors: dashboard" begin
    # Absent section: the launcher terminals default open, the receiver
    # status panel default off; every flag is validated as a boolean.
    db = TelemetryCore.dashboard_settings(Dict{String,Any}())
    @test db.open_live_viewer && db.open_receiver_log && db.open_emitter_log
    @test db.receiver_status_panel == false
    cfg = valid_test_cfg()
    cfg["dashboard"] = Dict{String,Any}("receiver_status_panel" => true)
    @test TelemetryCore.dashboard_settings(cfg).receiver_status_panel
    @test TelemetryCore.validate_config(cfg) isa AbstractDict
    cfg["dashboard"]["receiver_status_panel"] = "yes"
    err = try
        TelemetryCore.dashboard_settings(cfg)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError &&
          occursin("[CONFIG] dashboard.receiver_status_panel", err.msg)
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)
end

@testset "Capacity balance and profile-mean guardrail" begin
    start, dur = Time(8), Second(8 * 3600)
    mean_of(profile; k = 10.0, σ = 0.15) =
        TelemetryCore.profile_mean(TelemetryCore.VisibilityModel(start, dur, profile, k, σ))
    @test mean_of("flat") ≈ 1.0 atol = 1e-12
    @test mean_of("sine") ≈ 0.5 atol = 1e-9
    @test mean_of("sigmoid") ≈ log(cosh(10.0)) / 10 rtol = 1e-9
    @test mean_of("sigmoid"; k = 4.0) ≈ log(cosh(4.0)) / 4 rtol = 1e-9
    # σ √(2π) erf(1 / (2√2 σ)) at σ = 0.15, evaluated to 12 digits offline.
    @test mean_of("gaussian") ≈ 0.375671592766 rtol = 1e-9
    @test mean_of("gaussian"; σ = 0.3) > mean_of("gaussian")

    # Abstraction form: 20 batches/h × 0.5 × 8 h = 80 batches per pass against
    # 600 s batches, 144 per day.
    base = valid_test_cfg()
    balance = TelemetryCore.capacity_balance(base)
    @test !balance.rate_form
    @test balance.pass_hours ≈ 8.0 rtol = 1e-12
    @test balance.capacity_per_pass ≈ 80.0 rtol = 1e-9
    @test balance.produced_per_day ≈ 144.0 rtol = 1e-12

    # Rate pair under a shaped profile: the validator warns with the profile
    # mean and the balance; under the flat profile it stays silent.
    rates = deepcopy(base)
    delete!(rates["telemetry"], "max_batches_per_hour")
    rates["telemetry"]["downlink_kbps"] = 230.0
    rates["telemetry"]["onboard_data_rate_kbps"] = 75.0
    shaped = TelemetryCore.capacity_balance(rates)
    @test shaped.rate_form
    @test shaped.capacity_per_pass ≈ 3600 / (600 * 75 / 230) * 0.5 * 8 rtol = 1e-9
    @test_logs (:warn, r"mean 0\.5 over the pass") match_mode=:any TelemetryCore.validate_config(
        rates,
    )
    rates["telemetry"]["bandwidth_profile"] = "flat"
    records, _ = Test.collect_test_logs(() -> TelemetryCore.validate_config(rates))
    @test !any(occursin("pass profile", string(r.message)) for r in records)
    @test TelemetryCore.capacity_balance(rates).profile_mean ≈ 1.0 rtol = 1e-12
end

@testset "Run identifier and configuration hash" begin
    cfg = valid_test_cfg()
    h = TelemetryCore.config_sha256(cfg)
    @test length(h) == 64
    # The provenance section is not part of the parameter identity.
    stamped = deepcopy(cfg)
    stamped["provenance"] =
        Dict{String,Any}("platform" => Dict{String,Any}("hostname" => "x"))
    @test TelemetryCore.config_sha256(stamped) == h
    changed = deepcopy(cfg)
    changed["simulation"]["speed_up"] = 2 * cfg["simulation"]["speed_up"]
    @test TelemetryCore.config_sha256(changed) != h
    id = TelemetryCore.generate_run_id(cfg)
    @test occursin(r"^RUN_cfg=[0-9a-f]{8}_pid=\d+_t=\d{8}_\d{6}$", id)
    @test startswith(id, "RUN_cfg=" * first(h, 8))
end

@testset "Manifest resolution" begin
    mktempdir() do dir
        project = joinpath(dir, "Project.toml")
        write(project, "")
        @test TelemetryCore.manifest_beside(project) === nothing
        plain = joinpath(dir, "Manifest.toml")
        touch(plain)
        @test TelemetryCore.manifest_beside(project) == plain
        versioned = joinpath(dir, "Manifest-v$(VERSION.major).$(VERSION.minor).toml")
        touch(versioned)
        @test TelemetryCore.manifest_beside(project) == versioned
        resolved = TelemetryCore.active_manifest_path(project)
        expected =
            isdefined(Base, :project_file_manifest_path) ?
            Base.project_file_manifest_path(project) :
            TelemetryCore.manifest_beside(project)
        @test resolved isa String && endswith(resolved, ".toml") && resolved == expected
    end
end

@testset "Session-figure keys and the figure-stage RAM estimate" begin
    base = valid_test_cfg()
    pp = TelemetryCore.post_processing_settings(base)
    @test pp.session_figures === true && pp.session_figures_max === 0
    for (key, value) in (
        ("session_figures", "yes"),
        ("session_figures_max", -1),
        ("session_figures_max", 2.5),
    )
        bad = valid_test_cfg()
        bad["post_processing"] = Dict{String,Any}(key => value)
        @test_throws ArgumentError TelemetryCore.post_processing_settings(bad)
        @test_throws ArgumentError TelemetryCore.validate_config(bad)
    end
    for key in ("session_figures", "session_figures_max")
        @test key in TelemetryCore.KNOWN_CONFIG_KEYS["post_processing"]
    end

    # The estimator counts two files (PNG and PDF) per session figure.
    est = TelemetryCore.estimate_artifacts(base)
    off = valid_test_cfg()
    off["post_processing"] = Dict{String,Any}("session_figures" => false)
    windows = (est.file_count - TelemetryCore.estimate_artifacts(off).file_count) ÷ 2
    @test windows >= 1
    capped = valid_test_cfg()
    capped["post_processing"] = Dict{String,Any}("session_figures_max" => 1)
    @test est.file_count - TelemetryCore.estimate_artifacts(capped).file_count ==
          2 * (windows - 1)
    loose = valid_test_cfg()
    loose["post_processing"] = Dict{String,Any}("session_figures_max" => 10_000)
    @test TelemetryCore.estimate_artifacts(loose).file_count == est.file_count

    # The figure stage enters the RAM gate with a fixed term and one per
    # metrics row.
    calibration = TelemetryCore.STORAGE_CALIBRATION_DEFAULTS
    @test est.figure_ram_bytes ≈
          calibration.bytes_figure_stage +
          min(est.metrics_rows, 3 * est.n_batches) * calibration.bytes_figure_row
    tight = valid_test_cfg()
    tight["storage"] = merge(
        get(tight, "storage", Dict{String,Any}()),
        Dict{String,Any}("max_ram_gb" => 0.1),
    )
    @test_throws TelemetryCore.StorageBudgetError with_logger(NullLogger()) do
        TelemetryCore.check_storage_limits(tight)
    end
end

@testset "Table I/O: stated column types and the timestamp form" begin
    mktempdir() do dir
        path = joinpath(dir, "events.csv")
        table = DataFrame(
            SimTime = [
                DateTime(2035, 1, 4, 12, 0, 36),
                DateTime(2035, 1, 1, 6, 18, 21, 600),
                DateTime(2026, 9, 24, 2, 1, 17, 51),
            ],
            Batch = ["ARCH_batch_1", "LIVE_batch_2", "SCHEDULED"],
            AvailableAt = [missing, DateTime(2035, 1, 4, 13), missing],
            Delay_Hours = [missing, 1.5, missing],
            Live = [false, true, false],
        )
        @test TelemetryCore.write_table(path, table) == path
        @test readlines(path) == [
            "SimTime,Batch,AvailableAt,Delay_Hours,Live",
            "2035-01-04T12:00:36.0,ARCH_batch_1,,,false",
            "2035-01-01T06:18:21.6,LIVE_batch_2,2035-01-04T13:00:00.0,1.5,true",
            "2026-09-24T02:01:17.051,SCHEDULED,,,false",
        ]
        back = TelemetryCore.read_table(path)
        @test eltype(back.SimTime) === DateTime && eltype(back.Batch) === String
        @test eltype(back.AvailableAt) === Union{Missing,DateTime}
        @test back.SimTime == table.SimTime && isequal(back.AvailableAt, table.AvailableAt)
        @test back.Live == table.Live && isequal(back.Delay_Hours, table.Delay_Hours)
        # Appending keeps one header and the same form.
        TelemetryCore.write_table(path, table[1:1, :]; append = true)
        @test length(readlines(path)) == 5
        @test last(readlines(path)) == "2035-01-04T12:00:36.0,ARCH_batch_1,,,false"
        # A second round trip reproduces the file byte for byte.
        again = joinpath(dir, "again.csv")
        TelemetryCore.write_table(again, TelemetryCore.read_table(path))
        @test read(again) == read(path)
        @test TelemetryCore.timestamp_text(missing) === missing
    end
end

@testset "Declared-hole feed writer" begin
    mktempdir() do dir
        origin = DateTime(2035, 1, 1, 4, 48)
        feed = TelemetryCore.HoleFeed(dir, origin, 4.0, 2400)
        t = DateTime(2035, 1, 1, 9)
        # Rows given directly; an empty range writes nothing.
        @test TelemetryCore.declare_hole!(feed, t, "lost", "LIVE_batch_3", 4801:7200)
        @test !TelemetryCore.declare_hole!(feed, t, "lost", "LIVE_batch_4", 10:9)
        @test countlines(joinpath(dir, "holes.csv")) == 2
        # A generation gap on the payload grid; an empty gap writes nothing.
        @test TelemetryCore.declare_gap_hole!(
            feed,
            t,
            "scheduled",
            DateTime(2035, 1, 1, 6),
            DateTime(2035, 1, 1, 6, 10),
        )
        @test !TelemetryCore.declare_gap_hole!(
            feed,
            t,
            "scheduled",
            DateTime(2035, 1, 1, 6),
            DateTime(2035, 1, 1, 6),
        )
        # A batch: rows from its payload_row stamp, or from its index without metadata.
        stamped = joinpath(dir, "ground", "LIVE_batch_5")
        mkpath(stamped)
        write(
            joinpath(stamped, "metadata.json"),
            """{"batch_id":5,"payload_row":7201,"segment_count":1,""" *
            """"content_epoch":"2035-01-01T05:18:00","created_at":"2035-01-01T05:19:00"}""",
        )
        @test TelemetryCore.declare_batch_hole!(feed, t, "pruned", stamped)
        unstamped = joinpath(dir, "ground", "ARCH_batch_2")
        mkpath(unstamped)
        @test TelemetryCore.declare_batch_hole!(feed, t, "pruned", unstamped)

        held = TelemetryCore.read_hole_feed(dir)
        @test nrow(held) == 4
        @test names(held) == [
            "DeclaredAt",
            "Cause",
            "Batch",
            "RowFirst",
            "RowLast",
            "ContentStart",
            "ContentEnd",
        ]
        @test eltype(held.DeclaredAt) == DateTime
        @test held.Cause == ["lost", "scheduled", "pruned", "pruned"]
        @test ismissing(held.Batch[2])
        @test held.RowFirst[2] == 17281 && held.RowLast[2] == 19680
        @test held.ContentStart[2] == DateTime(2035, 1, 1, 6) &&
              held.ContentEnd[2] == DateTime(2035, 1, 1, 6, 10)
        @test held.ContentStart[1] == TelemetryCore.payload_row_time(origin, 4.0, 4801)
        @test held.RowFirst[3] == 7201 && held.RowLast[3] == 9600
        @test held.RowFirst[4] == 2401 && held.RowLast[4] == 4800
        # The cursor: rows beyond the first `after`; an absent feed is an empty table.
        @test nrow(TelemetryCore.read_hole_feed(dir; after = 3)) == 1
        @test nrow(TelemetryCore.read_hole_feed(dir; after = 9)) == 0
        absent = TelemetryCore.read_hole_feed(joinpath(dir, "none"))
        @test nrow(absent) == 0 && names(absent) == names(held)

        # The start of an open recorder gap, nothing once it has closed.
        rec = joinpath(dir, "rec")
        mkpath(rec)
        TelemetryCore.log_tx_event(rec, DateTime(2035, 1, 1, 5), "RECORDER", "gap_start")
        @test TelemetryCore.open_recorder_gap_start(rec) == DateTime(2035, 1, 1, 5)
        @test TelemetryCore.open_recorder_gap(rec)
        TelemetryCore.log_tx_event(rec, DateTime(2035, 1, 1, 6), "RECORDER", "gap_end")
        @test TelemetryCore.open_recorder_gap_start(rec) === nothing
        @test !TelemetryCore.open_recorder_gap(rec)
        empty_dir = joinpath(dir, "empty")
        mkpath(empty_dir)
        @test TelemetryCore.open_recorder_gap_start(empty_dir) === nothing
    end
end
