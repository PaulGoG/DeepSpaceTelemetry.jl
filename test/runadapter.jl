# The reference run adapter: the six questions answered from the file
# contract of a lossy tick run with a marker, a scheduled generation gap, and
# declared label spans, the gap tracker against the gap table, the marker
# rows, the label-span table and its regeneration, the descriptor, and the
# version check.

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
            "low_latency_after_hours" => 1.0,
            "low_latency_duration_hours" => 0.5,
        ),],
    )
    cfg["disruption"] = Dict{String,Any}(
        "events" => Any[Dict{String,Any}(
            "type" => "antenna_repointing",
            "label" => "repoint",
            "affects" => "generation",
            "start_day" => 0.08,
            "duration_hours" => 0.25,
        ),],
    )
    cfg["labels"] = Any[
        Dict{String,Any}(
            "label" => "mbhb_1",
            "label_start_index" => 100,
            "label_end_index" => 2500,
        ),
        Dict{String,Any}(
            "label" => "mbhb_2",
            "label_start_index" => 50,
            "label_end_index" => 10,
        ),
    ]
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
        # The label spans of the scenario sit beside the markers, on the payload grid.
        spans = RunAdapter.label_spans(run)
        by_class(c) = [s for s in spans if s.class == c]
        @test isfile(joinpath(run_dir, "label_spans.csv"))
        @test all(s.class in Masks.LABEL_SPAN_CLASSES for s in spans)
        @test issorted(first(s.rows) for s in spans)
        @test by_class("initial_downtime")[1].rows == 1:17280
        labeled = by_class("label")
        @test length(labeled) == 1 &&
              labeled[1].label == "mbhb_1" &&
              labeled[1].rows == 100:2500
        gap = by_class("generation_gap")
        @test length(gap) == 1 &&
              gap[1].type == "antenna_repointing" &&
              gap[1].label == "repoint"
        @test gap[1].rows == 44929:48528
        ll = by_class("low_latency")
        @test length(ll) == 1 && ll[1].type == "triggered" && ll[1].label == "transient"
        @test ll[1].rows == 53281:60480
        pass = by_class("contact")
        @test length(pass) == 1 && pass[1].type == "pass" && pass[1].rows == 46081:86400
        @test all(
            s.content_start == RunAdapter.row_time(g, first(s.rows)) &&
                s.content_end == RunAdapter.row_time(g, last(s.rows) + 1) for s in spans
        )
        @test isempty(by_class("blackout")) && isempty(by_class("recovery"))
        # Post-processing regenerates the table only when it is absent (runs before 2.6.0).
        rm(joinpath(run_dir, "label_spans.csv"))
        with_logger(NullLogger()) do
            Supervisor.post_process!(
                Supervisor.post_processing_plan(TelemetryCore.load_run_config(run_dir)),
                run_dir;
                orig_stdout = devnull,
            )
        end
        @test RunAdapter.label_spans(run) == spans
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
        @test haskey(descriptor["products"], "label_spans.csv")
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
