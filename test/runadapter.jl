# The reference run adapter: the five questions answered from the file
# contract of a lossy tick run with a marker and a scheduled generation gap,
# the gap tracker against the gap table, the marker rows, the descriptor,
# and the version check.

@testset "Run adapter" begin
    cfg = TelemetryCore.load_config(
        joinpath(TelemetryCore.PROJECT_ROOT, "scenarios", "deterministic_1d.toml"),
    )
    cfg["simulation"]["mission_days"] = 0.2
    cfg["simulation"]["initial_downtime_days"] = 0.05
    cfg["packet_loss"]["p_loss"] = 0.3
    cfg["post_processing"]["session_figures"] = false
    cfg["post_processing"]["state_raster"] = false
    cfg["post_processing"]["alert_latency"] = false
    cfg["events"] = Dict{String,Any}(
        "markers" => Any[Dict{String,Any}(
            "time" => "2035-01-01T07:30:00",
            "label" => "transient",
        ),],
    )
    cfg["disruption"] = Dict{String,Any}(
        "events" => Any[Dict{String,Any}(
            "type" => "antenna_repointing",
            "affects" => "generation",
            "start_day" => 0.08,
            "duration_hours" => 0.25,
        ),],
    )
    run_id = "TEST_RUN_adapter_pid$(getpid())"
    run_dir = with_logger(NullLogger()) do
        Supervisor.run_mission(cfg; run_id = run_id, orig_stdout = devnull)
    end
    try
        run = RunAdapter.open_run(run_id)          # by identifier
        @test RunAdapter.open_run(run_dir).run_dir == run.run_dir   # by path
        g = RunAdapter.run_geometry(run)
        @test g.points_per_batch == 2400 && g.mode == "tick" && g.payload_rows === nothing
        @test g.payload_origin == DateTime(2035, 1, 1, 6) - Hour(1) - Minute(12)
        @test RunAdapter.run_state(run) === :complete && RunAdapter.record_final(run)
        @test RunAdapter.time_row(g, RunAdapter.row_time(g, 4801)) == 4801
        batches = RunAdapter.list_batches(run)
        @test issorted(b.index for b in batches)
        @test all(length(b.rows) == g.points_per_batch for b in batches)
        rx = TelemetryCore.read_table(joinpath(run_dir, "events_rx.csv"))
        lost = Set(String.(rx.Batch[rx.Event .== "lost"]))
        @test !isempty(lost)
        @test Set(b.name for b in batches if b.state === :lost) == lost
        @test all(b.content_epoch == RunAdapter.row_time(g, first(b.rows)) for b in batches)
        # A batch on both sides of the scheduled gap keeps its stamped rows.
        tx = TelemetryCore.read_table(joinpath(run_dir, "events_tx.csv"))
        @test count(==("gap_start"), tx.Event) == 1
        payload = RunAdapter.read_batch(
            run,
            first(b.name for b in batches if b.state === :ground),
        )
        @test payload isa Vector{Float32} && length(payload) == g.points_per_batch
        @test_throws ArgumentError RunAdapter.read_batch(run, "LIVE_batch_999999")
        events = RunAdapter.arrival_events(run)
        @test length(events) == nrow(rx)
        @test events[1].event in (:ingested, :retry, :lost) && events[1].attempt >= 0
        @test length(RunAdapter.arrival_events(run; after = length(events) - 3)) == 3
        @test isempty(RunAdapter.arrival_events(run; after = length(events)))
        # Markers carry their payload row, in the file and through the adapter.
        marks = RunAdapter.markers(run)
        @test length(marks) == 1 && marks[1].label == "transient"
        @test marks[1].row == RunAdapter.time_row(g, DateTime(2035, 1, 1, 7, 30))
        @test "PayloadRow" in
              names(TelemetryCore.read_table(joinpath(run_dir, "markers.csv")))
        # The tracker declares what the gap table lists for the causes a feed
        # can announce, and nothing twice.
        tracker = RunAdapter.GapTracker(run)
        holes = RunAdapter.declare!(tracker)
        @test isempty(RunAdapter.declare!(tracker)) &&
              isempty(RunAdapter.open_gaps(tracker))
        table = Masks.gap_table(run_dir)
        announced = ("lost", "pruned", "stream", "scheduled", "recorder")
        @test Set((h.cause, first(h.rows), last(h.rows)) for h in holes) == Set(
            (Symbol(r.Cause), r.RowFirst, r.RowLast) for
            r in eachrow(table) if r.Cause in announced
        )
        @test any(h -> h.cause === :scheduled && ismissing(h.batch), holes)
        @test all(h -> h.content_end > h.content_start, holes)
        # The descriptor names the run, the producer, and the products with
        # their hashes.
        descriptor = TOML.parsefile(joinpath(run_dir, "descriptor.toml"))
        @test descriptor["run_id"] == run_id && descriptor["mode"] == "tick"
        @test descriptor["schema"] == "deepspacetelemetry-run/1"
        @test descriptor["points_per_batch"] == 2400 && descriptor["rng_seed"] == 1
        @test haskey(descriptor["products"], "events_rx.csv") &&
              haskey(descriptor["products"], "masks/gaps.csv")
        @test descriptor["products"]["events_rx.csv"]["sha256"] ==
              bytes2hex(open(TelemetryCore.sha256, joinpath(run_dir, "events_rx.csv")))
        # A run of a producer before the payload-row stamps is refused; one
        # without a recorded version is opened with a warning.
        old = joinpath(TelemetryCore.runs_root(), run_id * "_old")
        cp(run_dir, old)
        snapshot = joinpath(old, "config_snapshot.toml")
        text = read(snapshot, String)
        write(
            snapshot,
            replace(text, r"package_version = \"[^\"]*\"" => "package_version = \"2.0.1\""),
        )
        @test_throws ArgumentError RunAdapter.open_run(old)
        @test RunAdapter.open_run(old; minimum_version = v"2.0.0").geometry.package_version ==
              "2.0.1"
        write(snapshot, replace(text, r"\s*package_version = \"[^\"]*\"\n" => "\n"))
        @test (@test_logs (:warn, r"no producer version") RunAdapter.open_run(old)) isa
              RunAdapter.RunHandle
        rm(old; recursive = true, force = true)
        @test_throws ArgumentError RunAdapter.open_run(
            joinpath(TelemetryCore.runs_root(), "absent"),
        )
    finally
        rm(run_dir; recursive = true, force = true)
    end
end
