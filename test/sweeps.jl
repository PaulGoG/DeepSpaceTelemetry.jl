# Ensembles on the tick clock: two seeds of a short mission with an override,
# serial and two at once, summarized into one table with its provenance.

@testset "Sweeps" begin
    cfg = TelemetryCore.load_config(
        joinpath(TelemetryCore.PROJECT_ROOT[], "scenarios", "deterministic_1d.toml"),
    )
    cfg["simulation"]["mission_days"] = 0.1
    cfg["simulation"]["initial_downtime_days"] = 0.05
    @test Sweeps.parse_override("true") === true && Sweeps.parse_override("3") === 3
    @test Sweeps.parse_override("0.25") === 0.25 &&
          Sweeps.parse_override("\"flat\"") == "flat"
    @test Sweeps.split_override("packet_loss.p_loss=0.2") == ("packet_loss.p_loss", "0.2")
    @test_throws ArgumentError Sweeps.split_override("p_loss")
    one = Sweeps.sweep_configuration(cfg, 7; overrides = ["packet_loss.p_loss=0.2"])
    @test one["simulation"]["mode"] == "tick" && one["simulation"]["rng_seed"] == 7
    @test one["packet_loss"]["p_loss"] == 0.2
    @test one["post_processing"]["session_figures"] == false &&
          one["post_processing"]["generate_mask_timeline"] == false
    @test_throws ArgumentError Sweeps.apply_override!(Dict{String,Any}(), "p_loss", 0.2)
    prefix = "TEST_SWEEP_pid$(getpid())"
    result = with_logger(NullLogger()) do
        Sweeps.run_sweep(
            cfg;
            prefix = prefix,
            seeds = 1:2,
            overrides = ["packet_loss.p_loss=0.3"],
            workers = 0,
        )
    end
    runs = [joinpath(TelemetryCore.runs_root(), "$(prefix)_seed$s") for s in 1:2]
    try
        summary = result.summary
        @test nrow(summary) == 2 && summary.seed == [1, 2]
        @test summary.run_id == basename.(runs)
        @test all(isfile(joinpath(r, "RUN_COMPLETE")) for r in runs)
        @test isfile(joinpath(runs[1], "delivery_delay.csv"))
        plots = joinpath(runs[1], "plots")
        @test !isdir(plots) || isempty(readdir(plots))
        @test !isfile(joinpath(runs[1], "masks", "telemetry_mask_timeline.csv"))
        @test isfile(joinpath(runs[1], "masks", "gaps.csv"))
        # The span fixes the production; the seeds move the losses only.
        @test summary.generated[1] == summary.generated[2]
        @test all(summary.ground_total .+ summary.lost .<= summary.generated)
        @test all(0 .<= summary.within_requirement .<= 1)
        @test isfile(joinpath(result.dir, "summary.csv")) &&
              isfile(joinpath(result.dir, "sweep.toml"))
        provenance = TOML.parsefile(joinpath(result.dir, "sweep.toml"))
        @test provenance["seeds"] == [1, 2] && provenance["mode"] == "tick"
        @test provenance["overrides"] == ["packet_loss.p_loss=0.3"]
        @test provenance["base_config_sha256"] == TelemetryCore.config_sha256(cfg)
        @test TOML.parsefile(joinpath(runs[1], "config_snapshot.toml"))["packet_loss"]["p_loss"] ==
              0.3
        @test_throws ArgumentError Sweeps.run_sweep(cfg; prefix = "bad prefix", seeds = 1:1)
        @test_throws ArgumentError Sweeps.run_sweep(cfg; prefix = prefix, seeds = [1, 1])
        # Two members at once (tasks on the threads there are) reproduce the
        # serial members: the same table and the same event logs to the byte.
        concurrent = with_logger(NullLogger()) do
            Sweeps.run_sweep(
                cfg;
                prefix = prefix * "_c",
                seeds = 1:2,
                overrides = ["packet_loss.p_loss=0.3"],
                workers = 2,
            )
        end
        append!(
            runs,
            [joinpath(TelemetryCore.runs_root(), "$(prefix)_c_seed$s") for s in 1:2],
        )
        try
            @test isequal(
                select(concurrent.summary, Not(:run_id)),
                select(summary, Not(:run_id)),
            )
            for s in 1:2, log in ("events_tx.csv", "events_rx.csv", "holes.csv")
                serial, parallel = joinpath(runs[s], log), joinpath(runs[s+2], log)
                @test isfile(serial) == isfile(parallel)
                isfile(serial) && @test read(serial) == read(parallel)
            end
        finally
            rm(concurrent.dir; recursive = true, force = true)
        end
    finally
        foreach(r -> rm(r; recursive = true, force = true), runs)
        rm(result.dir; recursive = true, force = true)
    end
end
