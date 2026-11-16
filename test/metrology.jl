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
                MetrologyFigures.plot_alert_latency(dir; lookback_hours = 0.25),
                "alert_latency.png",
            )
            Metrology.write_metrology_tables(dir; lookback_hours = 0.25)
        end
        @test isfile(joinpath(dir, "alert_latency.csv"))
        @test isfile(joinpath(dir, "plots", "alert_latency.pdf"))
    end
end

@testset "Kaplan–Meier quantiles" begin
    q = Metrology.km_quantile
    # Complete data: Ŝ falls by 1/4 at each of 1, 2, 3, 4.
    t = [1.0, 2.0, 3.0, 4.0]
    all_observed = trues(4)
    @test q(t, all_observed, 0.25) == 1.0
    @test q(t, all_observed, 0.5) == 2.0
    @test q(t, all_observed, 0.75) == 3.0
    # One censoring at 3: Ŝ(1) = 4/5, Ŝ(2) = 3/5, three at risk after 2 and
    # two after the censoring, Ŝ(4) = 3/5 · 1/2 = 3/10, Ŝ(5) = 0.
    t = [1.0, 2.0, 3.0, 4.0, 5.0]
    observed = [true, true, false, true, true]
    @test q(t, observed, 0.25) == 2.0
    @test q(t, observed, 0.5) == 4.0
    @test q(t, observed, 0.75) == 5.0
    # A tie of an event and a censoring at 2: the event comes first,
    # Ŝ(2) = 2/3, then Ŝ(3) = 0.
    @test q([2.0, 2.0, 3.0], [true, false, true], 0.25) == 2.0
    @test q([2.0, 2.0, 3.0], [true, false, true], 0.5) == 3.0
    # Windows that never complete stay at risk: the median is not reached.
    @test q([1.0, Inf, Inf, Inf], [true, false, false, false], 0.25) == 1.0
    @test isnan(q([1.0, Inf, Inf, Inf], [true, false, false, false], 0.5))
    @test isnan(q([1.0, 2.0], [false, false], 0.5))
    @test isnan(q(Float64[], Bool[], 0.5))
    @test_throws ArgumentError q([1.0], [true], 1.0)
    @test_throws ArgumentError q([1.0, NaN], [true, true], 0.5)
end

@testset "Delivery compliance with pending and discarded batches" begin
    # Four batches against a 24 h requirement: two delivered within it, one
    # delivered late, one undelivered and not yet due at the run end.
    table = DataFrame(
        Batch = ["LIVE_batch_1", "ARCH_batch_2", "ARCH_batch_3", "LIVE_batch_4"],
        Live = [true, false, false, true],
        Delay_Hours = Union{Missing,Float64}[2.0, 20.0, 30.0, missing],
        LowLatency = [false, false, false, false],
        Due = [true, true, true, false],
    )
    s = Metrology.delivery_compliance(table, 24.0)
    @test s.within == 2 && s.generated == 4
    @test s.fraction_within == 2 / 4
    @test s.pending == 1 && s.due == 3
    @test s.fraction_within_resolved == 2 / 3
    s = Metrology.delivery_compliance(table, 24.0; discarded = 2)
    @test s.fraction_within_resolved == 2 / 5
end

@testset "Alert latency with censored windows (synthetic schedule)" begin
    # The schedule of the testset above with ARCH_batch_1 never delivered;
    # the run ends at t0 + 1 h (60 s × 60). Realized: LIVE_5 (t_m = t0 + 3
    # min) completes its windows at 1, 1, 2, 3, 5 min for k = 0 … 4, and its
    # window at k = 5 holds ARCH_1, censored at 57 min; LIVE_6 (t_m = t0 + 6
    # min) completes at 1, 1, 1, 1, 1, 2 min. The FIFO drain hands the five
    # completions 4 … 8 min to ARCH_1 … LIVE_5, so LIVE_5 arrives at 8 min
    # (latency 5 min at every k) and LIVE_6 never (censored at 54 min).
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
        epochs = Dict(
            "ARCH_batch_1" => t0 - 4D,
            "ARCH_batch_2" => t0 - 3D,
            "ARCH_batch_3" => t0 - 2D,
            "ARCH_batch_4" => t0 - D,
            "LIVE_batch_5" => t0,
            "LIVE_batch_6" => t0 + D,
        )
        for (name, epoch) in epochs
            stage = name == "ARCH_batch_1" ? "link" : "ground"
            bdir = mkpath(joinpath(dir, stage, name))
            write(
                joinpath(bdir, "metadata.json"),
                """{"batch_id":$(TelemetryCore.batch_id(name)),"segment_count":3,"created_at":"$(epoch + D)","content_epoch":"$epoch","payload_row":$(1 + 720 * (TelemetryCore.batch_id(name) - 1))}""",
            )
            TelemetryCore.log_tx_event(dir, epoch + D, name, "gen")
        end
        for (name, t) in (
            ("LIVE_batch_5", t0 + Minute(4)),
            ("ARCH_batch_4", t0 + Minute(5)),
            ("ARCH_batch_3", t0 + Minute(6)),
            ("LIVE_batch_6", t0 + Minute(7)),
            ("ARCH_batch_2", t0 + Minute(8)),
        )
            TelemetryCore.log_rx_event(dir, t, name, "ingested", 0)
        end
        table = Metrology.alert_latency_table(dir; lookback_hours = 0.25)
        minutes = x -> x / 60
        @test table.N_Alerts_All == fill(2, 6)
        @test table.N_Censored_LIFO == [0, 0, 0, 0, 0, 1]
        @test table.N_Censored_FIFO == fill(1, 6)
        # Kaplan–Meier median: the smaller of two observed latencies; with
        # one of two censored beyond the other, the observed one.
        @test table.LIFO_KM_Median_Hours ≈ minutes.([1.0, 1.0, 1.0, 1.0, 1.0, 2.0]) rtol =
            1e-12
        @test table.FIFO_KM_Median_Hours ≈ minutes.(fill(5.0, 6)) rtol = 1e-12
        # The upper quartile is not reached where a censored window remains.
        @test isnan(table.LIFO_KM_Q75_Hours[6]) && all(isnan, table.FIFO_KM_Q75_Hours)
        @test table.LIFO_KM_Q75_Hours[1:5] ≈ minutes.([1.0, 1.0, 2.0, 3.0, 5.0]) rtol =
            1e-12
        # Complete cases: LIVE_5 alone (LIVE_6 has no FIFO delivery), and no
        # alert at k = 5, where LIVE_5's window is incomplete.
        @test table.N_Alerts == [1, 1, 1, 1, 1, 0]
        @test table.LIFO_Median_Hours[1:5] ≈ minutes.([1.0, 1.0, 2.0, 3.0, 5.0]) rtol =
            1e-12
        @test isnan(table.LIFO_Median_Hours[6])
    end
end

@testset "Recorder spans and lost batches in the metrology" begin
    # Batches of 3 min (3 segments of 60 s); the run ends at t0 + 30 min.
    snapshot(dir) = open(joinpath(dir, "config_snapshot.toml"), "w") do io
        write(
            io,
            """
            [simulation]
            speed_up = 60.0
            start_sim_time = "2035-01-01T06:00:00"
            mission_wall_seconds = 30.0
            [physics]
            data_source = "synthetic"
            sample_rate = 4.0
            segment_duration_sec = 60.0
            batch_size = 3
            """,
        )
    end
    t0 = DateTime(2035, 1, 1, 6)
    # Two recorder gaps, the second still open at the end of the log: 9 min
    # and 10 min, so round(19 / 3) = 6 whole batches.
    mktempdir() do dir
        snapshot(dir)
        TelemetryCore.log_tx_event(dir, t0, "RECORDER", "gap_start")
        TelemetryCore.log_tx_event(dir, t0 + Minute(9), "RECORDER", "gap_end")
        TelemetryCore.log_tx_event(dir, t0 + Minute(20), "RECORDER", "gap_start")
        @test Metrology.recorder_spans(dir) ==
              [(t0, t0 + Minute(9)), (t0 + Minute(20), t0 + Minute(30))]
        @test Metrology.discarded_batches(dir) == 6
        # A scheduled generation gap inside the first span produced no data:
        # 16 min discarded, round(16 / 3) = 5 batches.
        TelemetryCore.log_tx_event(dir, t0 + Minute(3), "SCHEDULED", "gap_start")
        TelemetryCore.log_tx_event(dir, t0 + Minute(6), "SCHEDULED", "gap_end")
        @test Metrology.recorder_spans(dir) == [
            (t0, t0 + Minute(3)),
            (t0 + Minute(6), t0 + Minute(9)),
            (t0 + Minute(20), t0 + Minute(30)),
        ]
        @test Metrology.discarded_batches(dir) == 5
        # A stream gap (an emitter outage) is not taken out: during an
        # overflow it starts where the recorder began to discard.
        TelemetryCore.log_tx_event(dir, t0 + Minute(20), "STREAM", "gap_start")
        TelemetryCore.log_tx_event(dir, t0 + Minute(25), "STREAM", "gap_end")
        @test Metrology.discarded_batches(dir) == 5
    end
    # A window that holds a batch lost for good never completes under the
    # realized doctrine. ARCH_1, ARCH_2 and LIVE_3 arrive (LIVE_3's window
    # back to δ = 6 min completes 11 min after its event); ARCH_7 is lost, so
    # LIVE_8's window back to δ = 6 min never completes. Censored at the run
    # end instead (6 min), it would leave LIVE_3 alone at risk and put the
    # upper quartile at 11 min; never completing, it keeps Ŝ(11 min) = 1/2.
    mktempdir() do dir
        snapshot(dir)
        D = Minute(3)
        batches = (
            ("ARCH_batch_1", t0, "ground", t0 + Minute(5)),
            ("ARCH_batch_2", t0 + D, "ground", t0 + Minute(19)),
            ("LIVE_batch_3", t0 + 2D, "ground", t0 + Minute(20)),
            ("ARCH_batch_7", t0 + 6D, "lost", nothing),
            ("LIVE_batch_8", t0 + 7D, "ground", t0 + Minute(25)),
        )
        for (name, epoch, stage, _) in batches
            bdir = mkpath(joinpath(dir, stage, name))
            write(
                joinpath(bdir, "metadata.json"),
                """{"batch_id":$(TelemetryCore.batch_id(name)),"segment_count":3,"created_at":"$(epoch + D)","content_epoch":"$epoch","payload_row":$(1 + 720 * (TelemetryCore.batch_id(name) - 1))}""",
            )
            TelemetryCore.log_tx_event(dir, epoch + D, name, "gen")
        end
        TelemetryCore.log_rx_event(dir, t0 + Minute(5), "ARCH_batch_1", "ingested", 0)
        TelemetryCore.log_rx_event(dir, t0 + Minute(19), "ARCH_batch_2", "ingested", 0)
        TelemetryCore.log_rx_event(dir, t0 + Minute(20), "LIVE_batch_3", "ingested", 0)
        TelemetryCore.log_rx_event(dir, t0 + Minute(23), "ARCH_batch_7", "lost", 1)
        TelemetryCore.log_rx_event(dir, t0 + Minute(25), "LIVE_batch_8", "ingested", 0)
        table = Metrology.alert_latency_table(dir; lookback_hours = 0.1)
        minutes = x -> x / 60
        @test table.Lookback_Hours ≈ [0.0, 0.05, 0.1]
        @test table.N_Alerts_All == [2, 2, 2]
        @test table.N_Censored_LIFO == [0, 0, 1]
        # Below δ = 6 min both windows hold the alert batch alone: 11 and
        # 1 min. At δ = 6 min, LIVE_3 observed at 11 min, LIVE_8 never.
        @test table.LIFO_KM_Median_Hours ≈ minutes.([1.0, 1.0, 11.0]) rtol = 1e-12
        @test table.LIFO_KM_Q75_Hours[1:2] ≈ minutes.([11.0, 11.0]) rtol = 1e-12
        @test isnan(table.LIFO_KM_Q75_Hours[3])
        # The counterfactual drain hands the 25 min completion to ARCH_7, so
        # LIVE_8 has no FIFO arrival: censored at the run end (6 min), not
        # never complete.
        @test table.N_Censored_FIFO == [1, 1, 1]
        @test table.FIFO_KM_Median_Hours ≈ minutes.(fill(11.0, 3)) rtol = 1e-12
        # The figure renders from these rows.
        path = with_logger(NullLogger()) do
            MetrologyFigures.plot_alert_latency(dir; plots_dir = joinpath(dir, "plots"))
        end
        @test path !== nothing && isfile(path)
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
                MetrologyFigures.plot_delivery_delay(dir; requirement_hours = 24.0),
                "delivery_delay.png",
            )
            Metrology.write_metrology_tables(dir)
        end
        @test isfile(joinpath(dir, "delivery_delay.csv"))
        @test isfile(joinpath(dir, "plots", "delivery_delay.pdf"))
    end

    @testset "Requirement label at a free slot beside its rule" begin
        anchor = MetrologyFigures.requirement_label_anchor
        none = Tuple{Float64,Float64}[]
        level(h...) = [(v, v) for v in h]                 # curves flat across the footprint
        y, h, s = anchor(level(0.36, 0.53), none, 0.0, 0.0, 0.35)   # room above the highest curve
        @test y ≈ 0.98 && h === :right && s === :left
        y, h, s = anchor(level(0.85, 0.95), none, 0.0, 0.0, 0.35)   # room only below the lowest
        @test y ≈ 0.02 && h === :left && s === :left
        y, h, s = anchor(level(0.1, 0.9), none, 0.0, 0.0, 0.35)     # widest gap between curves
        @test y ≈ 0.5 && h === :center && s === :left
        y, h, s = anchor([(0.1, 0.4), (0.9, 0.9)], none, 0.0, 0.0, 0.35)  # a curve climbing across the footprint narrows the gap
        @test y ≈ 0.65 && h === :center && s === :left
        y, h, s = anchor(level(0.3, 0.6, 0.9), level(0.3), 0.0, 0.0, 0.35)  # the left side is full, the right free above
        @test y ≈ 0.98 && h === :right && s === :right
        y, h, s = anchor(level(0.3, 0.6, 0.9), level(0.3, 0.6, 0.9), 0.0, 0.0, 0.35)  # nothing holds it: the top left
        @test y ≈ 0.98 && h === :right && s === :left
        y, h, s = anchor(none, none, 0.3, 0.3, 0.35)        # no curve reaches the rule
        @test y ≈ 0.98 && h === :right && s === :left
        y, h, s = anchor(level(0.9), none, 0.3, 0.0, 0.35)  # rule hidden below the block
        @test y ≈ 0.32 && h === :left && s === :left
        # A curve ending beside the rule (a live family delivered in full
        # before the requirement) fills the top of the left side; the
        # right side, where it is absent, holds the label.
        left = [(0.35, 0.40), (0.48, 0.55), (0.83, 0.95)]
        right = [(0.40, 0.40), (0.55, 0.55)]
        y, h, s = anchor(left, right, 0.0, 0.0, 0.40)
        @test y ≈ 0.98 && h === :right && s === :right
    end

    @testset "Occupancy of step curves across a band" begin
        occupancy = MetrologyFigures.requirement_label_occupancy
        Y = MetrologyFigures.Y_HEADROOM
        x = [0.0, 2.0, 4.0, 6.0]
        y = [0.0, 0.25, 0.5, 1.0]
        curves = ((x, y, true), (x, y, false))
        @test occupancy(curves, 8.0, 10.0) == []            # the curve ended before the band
        @test occupancy(curves, 3.0, 5.0) == [(0.25 / Y, 0.5 / Y)]
        @test occupancy(curves, 5.0, 9.0) == [(0.5 / Y, 1.0 / Y)]   # ends inside the band
        @test occupancy(curves, -1.0, 1.0) == [(0.0, 0.0)]          # band clipped at the origin, before the first step
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
    # window center), none half a year away, the plain window elsewhere.
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
    # one marker-triggered period on the evening of 3 April 2035.
    shipped = TelemetryCore.load_config(joinpath(dirname(@__DIR__), "config.toml"))
    @test length(TelemetryCore.contacts_settings(shipped).low_latency_periods) == 1
    @test TelemetryCore.is_visible(
        TelemetryCore.visibility_model(shipped),
        DateTime(2035, 4, 3, 21),
    )

    # Delivery-delay table: a batch ingested inside a low-latency period is
    # flagged and counted, also inside the nominal pass (09:00, in the second
    # period); `Due` is true when the content end plus the requirement
    # (0.96 h) falls at or before the mission end (07:00).
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
                [post_processing]
                delivery_requirement_hours = 0.96
                [[contacts.low_latency_periods]]
                start = "2035-01-01T06:00:00"
                duration_hours = 1.0
                [[contacts.low_latency_periods]]
                start = "2035-01-01T09:00:00"
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
        @test table.LowLatency == [true, true]
        @test Metrology.delivery_compliance(table, 24.0).via_low_latency == 2
        @test table.Due == [true, false]
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
                TelemetryCore.run_directory(stamp_id);
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
        tx = TelemetryCore.read_table(joinpath(stamp_dir, "events_tx.csv"))
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
                MetrologyFigures.plot_alert_latency(
                    dir;
                    lookback_hours = 0.1,
                    processing_latency_hours = 0.5,
                ),
                "alert_latency.png",
            )
            Metrology.write_metrology_tables(dir; lookback_hours = 0.1)
        end
        @test isfile(joinpath(dir, "alert_latency_markers.csv"))
    end
end
