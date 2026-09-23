# Figures: the standard layout helpers, the figure-product registry, the publication export, tick spacing.

@testset "Full-day session is always visible" begin
    model = TelemetryCore.VisibilityModel(Time(0), Second(24 * 3600), "flat")
    @test all(TelemetryCore.is_visible(model, DateTime(2035, 1, 1, h)) for h in 0:23)
    @test TelemetryCore.get_bandwidth_factor(model, DateTime(2035, 1, 1, 12)) == 1.0
    partial = TelemetryCore.VisibilityModel(Time(20), Second(8 * 3600), "flat")
    @test TelemetryCore.is_visible(partial, DateTime(2035, 1, 1, 2))
    @test !TelemetryCore.is_visible(partial, DateTime(2035, 1, 1, 12))
end

@testset "Figure-product registry and [post_processing] accessor" begin
    flags = map(product -> product.flag, TelemetryCore.FIGURE_PRODUCTS)
    @test allunique(flags)
    # Every registered product is a known key and has a renderer.
    for product in TelemetryCore.FIGURE_PRODUCTS
        @test String(product.flag) in TelemetryCore.KNOWN_CONFIG_KEYS["post_processing"]
        @test hasmethod(
            TelemetryCore.render_figure_product,
            Tuple{Val{product.flag},String,NamedTuple,NamedTuple},
        )
    end

    pp = TelemetryCore.post_processing_settings(valid_test_cfg())
    @test keys(pp.figures) == flags
    @test all(
        getproperty(pp.figures, product.flag) == product.default for
        product in TelemetryCore.FIGURE_PRODUCTS
    )

    # The flag contract holds for every product; the estimator counts one
    # figure (two files: PNG and PDF twin) per enabled product.
    all_on = valid_test_cfg()
    all_on["post_processing"] = Dict{String,Any}(String(flag) => true for flag in flags)
    n_on = TelemetryCore.estimate_artifacts(all_on).file_count
    for flag in flags
        bad = valid_test_cfg()
        bad["post_processing"] = Dict{String,Any}(String(flag) => "yes")
        @test_throws ArgumentError TelemetryCore.post_processing_settings(bad)
        @test_throws ArgumentError TelemetryCore.validate_config(bad)
        off = deepcopy(all_on)
        off["post_processing"][String(flag)] = false
        @test !getproperty(TelemetryCore.post_processing_settings(off).figures, flag)
        @test TelemetryCore.estimate_artifacts(off).file_count == n_on - 2
    end

    # Bounds of the numeric keys.
    for key in ("alert_lookback_hours", "delivery_requirement_hours")
        bad = valid_test_cfg()
        bad["post_processing"] = Dict{String,Any}(key => 0.0)
        @test_throws ArgumentError TelemetryCore.post_processing_settings(bad)
    end

    # A raster without its mask timeline is announced at validation.
    cfg = valid_test_cfg()
    cfg["post_processing"] = Dict{String,Any}("generate_mask_timeline" => false)
    @test_logs (:warn, r"state_raster") match_mode = :any TelemetryCore.validate_config(cfg)
    cfg["post_processing"]["state_raster"] = false
    logs, _ = Test.collect_test_logs(; min_level = Logging.Warn) do
        TelemetryCore.validate_config(cfg)
    end
    @test !any(occursin("state_raster", string(record.message)) for record in logs)

    # The plan carries every section parsed once.
    plan = Supervisor.mission_plan(valid_test_cfg(); run_id = "PLAN_SETTINGS")
    @test plan.post_processing == TelemetryCore.post_processing_settings(plan.cfg)
    @test plan.publication == TelemetryCore.publication_settings(plan.cfg)
    @test plan.ground == TelemetryCore.ground_settings(plan.cfg)
    @test plan.dashboard == TelemetryCore.dashboard_settings(plan.cfg)
    @test plan.contacts isa TelemetryCore.ContactsSettings
end

@testset "Standard layout helpers" begin
    full = PlotTheme.PlotStyle()
    @test full.scale == 1.0 && full.width == PlotTheme.FIGURE_WIDTH
    @test full.fontsize == PlotTheme.FONTSIZE && full.linewidth == PlotTheme.LINEWIDTH_DATA
    # A narrower figure is a miniature of the standard layout: every length
    # of the style carries the same factor.
    narrow = PlotTheme.style_for_width(100.0)
    @test narrow.scale ≈ 100.0 / 25.4 * 96 / PlotTheme.FIGURE_WIDTH
    for field in (
        :panel_height,
        :strip_height,
        :fontsize,
        :fontsize_tick,
        :fontsize_annotation,
        :linewidth,
        :linewidth_guide,
        :linewidth_edge,
        :markersize,
    )
        @test getfield(narrow, field) ≈ narrow.scale * getfield(full, field)
    end
    @test narrow.width == round(Int, narrow.scale * full.width)
    @test PlotTheme.scaled(narrow, 70) ≈ 70 * narrow.scale
    @test_throws ArgumentError PlotTheme.PlotStyle(0.0)

    # The legend comes in families and lists only what the figure draws.
    groups = MissionFigures.figure_legend_entries(;
        degraded = true,
        blackout = true,
        ramp = true,
        outage = false,
        scheduled_gap = true,
        recorder = false,
        low_latency = true,
        marker = true,
        lost = :strip,
    )
    @test [first(group) for group in groups] == ["Link", "Received", "Events"]
    @test all(length(group[2]) == length(group[3]) for group in groups)
    @test groups[1][3] == ["Nominal capacity", "Effective capacity", "Onboard buffer"]
    @test groups[2][3] == ["Total (live + archive)", "Archive (LIFO)", "Lost"]
    @test groups[3][3] == [
        "Blackout",
        "Recovery ramp",
        "Generation gap",
        "Low-latency period",
        "Event marker",
    ]
    quiet = MissionFigures.figure_legend_entries(;
        degraded = false,
        blackout = false,
        ramp = false,
        lost = :none,
    )
    @test quiet[1][3] == ["Link capacity", "Onboard buffer"] && isempty(quiet[3][3])

    # The legend takes the row count at which Makie measures it inside the
    # figure width, the figure the height its fixed panels require, and both
    # follow the scale of the style.
    Makie = PlotTheme.CairoMakie
    measured = map((full, narrow)) do style
        Makie.with_theme(PlotTheme.telemetry_theme(style)) do
            fig = Makie.Figure(size = (style.width, style.width))
            Makie.Axis(fig[1, 1])
            Makie.Axis(fig[2, 1])
            legend = PlotTheme.figure_legend!(fig, style, groups)
            PlotTheme.size_to_panels!(fig, 1 => style.panel_height, 2 => style.strip_height)
            (
                rows = legend.nbanks[],
                legend_width = legend.layoutobservables.autosize[][1],
                size = size(fig.scene),
            )
        end
    end
    @test measured[1].rows == measured[2].rows
    @test measured[1].legend_width <= full.width && measured[2].legend_width <= narrow.width
    @test measured[1].size[1] == full.width && measured[2].size[1] == narrow.width
    @test measured[1].size[2] > full.panel_height + full.strip_height
    @test measured[2].size[2] ≈ narrow.scale * measured[1].size[2] rtol = 0.02

    # An annotation moves to the end of the axis the upright rules leave free,
    # and stays put when both ends carry one.
    @test PlotTheme.annotation_side([0.1], 0.0, 10.0, 0.2) === :right
    @test PlotTheme.annotation_side([9.5], 0.0, 10.0, 0.2) === :left
    @test PlotTheme.annotation_side([0.5, 9.5], 0.0, 10.0, 0.2) === :right
    @test PlotTheme.annotation_side(Float64[], 0.0, 0.0, 0.2) === :right
    @test PlotTheme.annotation_fraction(full, "0 lost (0 %)") <
          PlotTheme.annotation_fraction(full, "1234 lost (12.34 %)")
    @test PlotTheme.annotation_fraction(full, "a"^500) == 0.45
    @test PlotTheme.annotation_fraction(narrow, "0 lost (0 %)") ≈
          PlotTheme.annotation_fraction(full, "0 lost (0 %)") rtol = 0.01
    # The lower panel of a stacked pair prunes the tick at its upper limit.
    pruned = PlotTheme.UpperPrunedTicks()
    @test PlotTheme.Makie.get_tickvalues(pruned, 0.0, 150.0) == [0.0, 50.0, 100.0]
    @test PlotTheme.Makie.get_tickvalues(pruned, 0.0, 30.0) == [0.0, 10.0, 20.0]
    @test PlotTheme.Makie.get_tickvalues(pruned, 0.0, 108.0) == [0.0, 50.0, 100.0]
    # Count-axis tick steps and recorder-span coalescing of the summary figure.
    @test MissionFigures.count_tick_step(4.0) == 2
    @test MissionFigures.count_tick_step(5.4) == 2
    @test MissionFigures.count_tick_step(31.05) == 20
    @test MissionFigures.count_tick_step(108.0) == 50
    @test MissionFigures.count_tick_step(1350.0) == 500
    spans = [(5.0, 6.0), (0.0, 1.0), (1.2, 2.0)]
    @test MissionFigures.coalesce_spans(spans, 0.5) == [(0.0, 2.0), (5.0, 6.0)]
    @test MissionFigures.coalesce_spans(spans, 0.1) == [(0.0, 1.0), (1.2, 2.0), (5.0, 6.0)]
    @test isempty(MissionFigures.coalesce_spans(NTuple{2,Float64}[], 1.0))
    @test MissionFigures.SESSION_PIN_HEIGHT < 1 / 1.2 + 0.1 &&
          MissionFigures.SESSION_PIN_HEIGHT > 1 / 1.2

    # The raster is skipped, not failed, when the run carries no timeline.
    @test MissionFigures.plot_state_raster(mktempdir()) === nothing
end

@testset "Publication figure export" begin
    base = valid_test_cfg()
    @test !TelemetryCore.publication_settings(base).enabled
    cfg = deepcopy(base)
    cfg["post_processing"] = Dict{String,Any}(
        "publication" => Dict{String,Any}(
            "enabled" => true,
            "format" => "svg",
            "column_width_mm" => 120.0,
        ),
    )
    settings = TelemetryCore.publication_settings(cfg)
    @test settings.enabled && settings.format == "svg" && settings.column_width_mm == 120.0
    @test TelemetryCore.validate_config(cfg) isa AbstractDict
    for (key, value) in (("format", "eps"), ("column_width_mm", 99.0), ("enabled", "yes"))
        bad = deepcopy(base)
        bad["post_processing"] =
            Dict{String,Any}("publication" => Dict{String,Any}(key => value))
        @test_throws ArgumentError TelemetryCore.publication_settings(bad)
    end

    # A synthetic run with a metrics profile and delivered batches: the
    # summary and the two metrology figures export at a 120 mm width
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
                column_width_mm = 120.0,
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
              record["column_width_mm"] == 120.0 &&
              record["format"] == "svg" &&
              length(record["figures"]) == 3 &&
              length(record["config_snapshot_sha256"]) == 64
        @test_throws ArgumentError DeepSpaceTelemetry.Publication.export_publication_figures(
            dir;
            format = "eps",
        )
    end
end

@testset "Mission summary tick spacing" begin
    # At most eleven day labels: daily up to 10 days, then 2, 5, 10, 20, 30,
    # 60-day steps, 120 days beyond 600.
    step_days(d) = MissionFigures.summary_tick_step_hours(Float64(d)) / 24
    @test step_days(7) == 1 && step_days(10) == 1
    @test step_days(12) == 2 && step_days(30) == 5 && step_days(45) == 5
    @test step_days(60) == 10 && step_days(200) == 20 && step_days(365) == 60
    @test step_days(1000) == 120
    @test all(d / step_days(d) <= 10 for d in 1:600)
end
