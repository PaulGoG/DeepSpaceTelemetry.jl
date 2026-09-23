# Metrology: alert latency, delivery delay, contact schedule and low-latency periods, event markers.

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
        @test table.Lookback_Hours ≈ [0.0, 0.05, 0.1, 0.15, 0.2, 0.25] rtol = 1e-12
        @test table.N_Alerts == fill(2, 6)
        minutes = x -> x / 60
        # Window-completeness medians over the two alerts (LIVE_5 at
        # t0 + 3 min, LIVE_6 at t0 + 6 min): realized completions 4, 5, 6, 7,
        # 8, 9 min for LIVE_5, ARCH_4, ARCH_3, LIVE_6, ARCH_2, ARCH_1; the
        # FIFO drain hands the same instants to ARCH_1 … LIVE_6 in order. The
        # window [t_m − δ, t_m) holds only the alert batch for δ ≤ D and one
        # older batch per further D.
        @test table.LIFO_Median_Hours ≈ minutes.([1.0, 1.0, 1.5, 2.0, 3.0, 4.0]) rtol =
            1e-12
        @test table.FIFO_Median_Hours ≈ minutes.(fill(4.0, 6)) rtol = 1e-12
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

@testset "Link-rate parameterization and delivery-delay metric" begin
    base = valid_test_cfg()
    # Physical rates: one 10-minute batch at 75 kbit/s production over a
    # 230 kbit/s downlink takes 600 · 75 / 230 s; capacity 18.4 batches/h.
    rates = deepcopy(base)
    delete!(rates["telemetry"], "max_batches_per_hour")
    rates["telemetry"]["downlink_kbps"] = 230.0
    rates["telemetry"]["onboard_data_rate_kbps"] = 75.0
    tel = TelemetryCore.telemetry_settings(rates)
    @test tel.nominal_batch_transfer_sec ≈ 600 * 75 / 230 rtol = 1e-12
    @test tel.max_batches_per_hour ≈ 3600 / (600 * 75 / 230) rtol = 1e-12
    @test tel.catch_up_ratio ≈ 230 / 75 rtol = 1e-12
    rates["telemetry"]["bandwidth_profile"] = "flat"  # the profile guardrail has its own testset
    @test TelemetryCore.validate_config(rates) isa AbstractDict
    both = deepcopy(rates)
    both["telemetry"]["max_batches_per_hour"] = 60.0
    @test_throws ArgumentError TelemetryCore.telemetry_settings(both)
    neither = deepcopy(base)
    delete!(neither["telemetry"], "max_batches_per_hour")
    @test_throws ArgumentError TelemetryCore.validate_config(neither)
    abstraction = TelemetryCore.telemetry_settings(base)
    @test isapprox(abstraction.nominal_batch_transfer_sec, 180.0; rtol = 1e-12) &&
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
        @test table.Delay_Hours[1] ≈ 30 + 3 / 60 rtol = 1e-12
        @test table.Delay_Hours[3] ≈ 7 / 60 rtol = 1e-12
        summary = Metrology.delivery_compliance(table, 24.0)
        @test summary.generated == 3 && summary.delivered == 2 && summary.within == 1
        @test summary.fraction_within ≈ 1 / 3 rtol = 1e-12
        with_logger(NullLogger()) do
            @test endswith(
                Metrology.plot_delivery_delay(dir; requirement_hours = 24.0),
                "delivery_delay.png",
            )
        end
        @test isfile(joinpath(dir, "delivery_delay.csv"))
        @test isfile(joinpath(dir, "plots", "delivery_delay.pdf"))
    end

    @testset "Requirement label at the free end of its rule" begin
        anchor = Metrology.requirement_label_anchor
        y, h = anchor([0.36, 0.53], 0.0, 0.35)          # room above the highest curve
        @test y ≈ 0.98 && h === :right
        y, h = anchor([0.85, 0.95], 0.0, 0.35)          # room only below the lowest
        @test y ≈ 0.02 && h === :left
        y, h = anchor([0.1, 0.9], 0.0, 0.35)            # widest interval between curves
        @test y ≈ 0.5 && h === :center
        y, h = anchor([0.3, 0.6, 0.9], 0.0, 0.35)       # nothing holds it: the top
        @test y ≈ 0.98 && h === :right
        y, h = anchor(Float64[], 0.3, 0.35)             # no curve reaches the rule
        @test y ≈ 0.98 && h === :right
        y, h = anchor([0.9], 0.3, 0.35)                 # rule hidden below the block
        @test y ≈ 0.32 && h === :left
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
    @test TelemetryCore.get_bandwidth_factor(sched, DateTime(2035, 1, 3, 1)) ≈ 1.0 rtol =
        1e-12
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
    @test TelemetryCore.get_bandwidth_factor(llp, DateTime(2035, 1, 5, 21)) ≈ 0.5 rtol =
        1e-12
    @test !TelemetryCore.is_visible(llp, DateTime(2035, 1, 5, 19))
    @test ChannelEffects.is_transmittable(
        ChannelEffects.LinkModel(llp),
        DateTime(2035, 1, 5, 21),
    )
    windows = TelemetryCore.contact_windows(llp, DateTime(2035, 1, 5), DateTime(2035, 1, 6))
    @test count(w -> w.low_latency, windows) == 1 && windows[end].label == "follow-up"
    stems = MissionFigures.session_figure_stems(
        llp,
        DateTime(2035, 1, 5, 6),
        DateTime(2035, 1, 7, 6),
    )
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
    @test settings.low_latency_periods[1].capacity ≈ 0.4 rtol = 1e-12
    model = TelemetryCore.visibility_model(cfg)
    @test TelemetryCore.get_bandwidth_factor(model, DateTime(2035, 1, 2, 21)) ≈ 0.4 rtol =
        1e-12
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
          isapprox(periods[1].capacity, 0.3; rtol = 1e-12) &&
          periods[1].label == "late"
    @test TelemetryCore.get_bandwidth_factor(
        TelemetryCore.visibility_model(cfg),
        DateTime(2035, 1, 2, 16, 30),
    ) ≈ 0.3 rtol = 1e-12
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
                VirtualInstrument.InstrumentState(
                    Emitter.instrument_epoch(start_sim, 0.01),
                    4.0,
                    60.0,
                    "synthetic",
                    "";
                    markers = [marker],
                ),
                start_sim,
                stamp_id;
                batch_size = 3,
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
            Masks.reconstruct_batch_states(
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
        @test inside.Lookback_Hours ≈ [0.0, 0.05, 0.1] rtol = 1e-12
        @test collect(inside.LIFO_Hours) ≈ [3.0, 4.0, 5.0] ./ 60 rtol = 1e-12
        @test collect(inside.FIFO_Hours) ≈ [5.0, 5.0, 5.0] ./ 60 rtol = 1e-12
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
