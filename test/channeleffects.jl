# ChannelEffects: loss models, disruption timeline, composite link model, config builders.

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

@testset "Transfer completion: integrated capacity" begin
    flat = TelemetryCore.VisibilityModel(Time(8, 0, 0), Second(8 * 3600), "flat")
    link = ChannelEffects.LinkModel(flat)
    far = DateTime(2035, 2, 1)
    day = DateTime(2035, 1, 1)
    # Full capacity inside a pass: one full-capacity transfer time, to the ms.
    work = 600 * 75 / 230 # 195.652… s, a 600 s batch at 75 / 230 kbit/s
    t0 = day + Hour(9)
    @test ChannelEffects.transfer_completion(link, t0, work, far) ==
          t0 + Millisecond(round(Int, 1000 * work))
    # Interrupted by the end of the pass (16:00) after 120 s, resumed at the
    # next pass (08:00) for the remaining 180 s.
    t0 = day + Hour(15) + Minute(58)
    resumed = day + Day(1) + Hour(8)
    @test ChannelEffects.transfer_completion(link, t0, 300.0, far) == resumed + Second(180)
    # A transfer that does not complete strictly before the horizon has no
    # completion instant.
    @test ChannelEffects.transfer_completion(link, t0, 300.0, resumed + Second(120)) ===
          nothing
    @test ChannelEffects.transfer_completion(link, t0, 300.0, resumed + Second(180)) ===
          nothing
    @test ChannelEffects.transfer_completion(
        link,
        t0,
        300.0,
        resumed + Second(180) + Millisecond(1),
    ) == resumed + Second(180)
    # A full blackout from 10:00 to 11:00 inside the pass suspends the
    # transfer: 60 s before it, 60 s after.
    blackout = ChannelEffects.DisruptionEvent(
        "test",
        "",
        day + Hour(10),
        day + Hour(11),
        day + Hour(11),
        1.0,
        5.0,
    )
    link_b = ChannelEffects.LinkModel(flat, ChannelEffects.DisruptionTimeline([blackout]))
    @test ChannelEffects.transfer_completion(
        link_b,
        day + Hour(9) + Minute(59),
        120.0,
        far,
    ) == day + Hour(11) + Minute(1)
    # A linear recovery ramp from 0 at 11:00 to 1 at 13:00 (R = 7200 s): from
    # the start of the ramp, ∫₀^τ s/R ds = τ²/(2R) = W, so τ = √(2RW). The
    # completing step is solved exactly for a linear capacity: the error is
    # the millisecond rounding.
    ramp = ChannelEffects.DisruptionEvent(
        "test",
        "",
        day + Hour(10),
        day + Hour(11),
        day + Hour(13),
        1.0,
        1.0,
    )
    link_r = ChannelEffects.LinkModel(flat, ChannelEffects.DisruptionTimeline([ramp]))
    exact = day + Hour(11) + Millisecond(round(Int, 1000 * sqrt(2 * 7200 * 600.0)))
    got = ChannelEffects.transfer_completion(link_r, day + Hour(11), 600.0, far)
    @test abs((got - exact).value) <= 2
    # A ramp shorter than one integration step (R = 120 s, W = 5 s): τ =
    # √1200 s ≈ 34.6 s, where a capacity held at the step's midpoint value
    # would give 20 s.
    short = ChannelEffects.DisruptionEvent(
        "test",
        "",
        day + Hour(10),
        day + Hour(11),
        day + Hour(11) + Second(120),
        1.0,
        1.0,
    )
    link_s = ChannelEffects.LinkModel(flat, ChannelEffects.DisruptionTimeline([short]))
    exact = day + Hour(11) + Millisecond(round(Int, 1000 * sqrt(1200.0)))
    got = ChannelEffects.transfer_completion(link_s, day + Hour(11), 5.0, far)
    @test abs((got - exact).value) <= 2
    # Completion a few steps into the 7200 s ramp (W = 10 s): τ = √144000 s,
    # inside the seventh 60 s step.
    exact = day + Hour(11) + Millisecond(round(Int, 1000 * sqrt(2 * 7200 * 10.0)))
    got = ChannelEffects.transfer_completion(link_r, day + Hour(11), 10.0, far)
    @test abs((got - exact).value) <= 2
    # The transmitting intervals of a transfer interrupted by the end of the
    # pass: the last 120 s of one pass and the first 180 s of the next.
    segments = Tuple{DateTime,DateTime}[]
    t0 = day + Hour(15) + Minute(58)
    ChannelEffects.transfer_completion(link, t0, 300.0, far; segments)
    @test segments == [
        (t0, day + Hour(16)),
        (day + Day(1) + Hour(8), day + Day(1) + Hour(8) + Minute(3)),
    ]
    # The sine profile over a pass of T = 8 h: F(s) = s/2 − T/(4π) sin(2πs/T)
    # is the integrated capacity from the start of the pass. The completion
    # of a 1800 s transfer started 1800 s into the pass solves
    # F(s) − F(1800) = 1800, by bisection here.
    sine = TelemetryCore.VisibilityModel(Time(8, 0, 0), Second(8 * 3600), "sine")
    T = 8 * 3600.0
    F(s) = s / 2 - T / (4π) * sin(2π * s / T)
    lo, hi = 1800.0, T
    for _ in 1:200
        mid = (lo + hi) / 2
        F(mid) - F(1800.0) < 1800.0 ? (lo = mid) : (hi = mid)
    end
    exact = day + Hour(8) + Millisecond(round(Int, 1000 * lo))
    got = ChannelEffects.transfer_completion(
        ChannelEffects.LinkModel(sine),
        day + Hour(8) + Second(1800),
        1800.0,
        far,
    )
    @test abs((got - exact).value) <= 50
    # Observed order of accuracy, against the same closed form on a one-hour
    # pass, where the capacity curves more per step: a 60 s transfer that
    # starts 300 s after the opening completes 354.813 s later. The midpoint
    # rule with a linear completing step is of second order, so each halving
    # of the step from 60 s to 7.5 s divides the error by about four (0.122,
    # 0.039, 0.011 and 0.003 s, the last within reach of the millisecond
    # rounding).
    hour = TelemetryCore.VisibilityModel(Time(8, 0, 0), Second(3600), "sine")
    G(s) = s / 2 - 3600 / (4π) * sin(2π * s / 3600)
    lo, hi = 300.0, 3600.0
    for _ in 1:200
        mid = (lo + hi) / 2
        G(mid) - G(300.0) < 60.0 ? (lo = mid) : (hi = mid)
    end
    errors = map((60.0, 30.0, 15.0, 7.5)) do step
        done = ChannelEffects.transfer_completion(
            ChannelEffects.LinkModel(hour),
            day + Hour(8) + Second(300),
            60.0,
            far;
            step_sec = step,
        )
        abs((done - (day + Hour(8))).value / 1000 - lo)
    end
    @test errors[1] < 0.2
    @test issorted(errors; rev = true)
    @test all(1.5 .< log2.(errors[1:3] ./ errors[2:4]) .< 2.5)
    @test_throws ArgumentError ChannelEffects.transfer_completion(link, day, 0.0, far)
    # Work equal to the capacity left in the pass completes at the end of the
    # pass. A partial outage holds the capacity at 1 − 0.86 = 0.14 over the
    # last four minutes of the pass: 240 s × 0.14 = 33.6 s of work. In
    # floating point the four steps leave a residual of about 4e-15 s, which
    # must not send the completion to the opening of the next pass.
    outage(severity) = ChannelEffects.LinkModel(
        flat,
        ChannelEffects.DisruptionTimeline([
            ChannelEffects.DisruptionEvent(
                "test",
                "",
                day + Hour(6),
                day + Hour(20),
                day + Hour(20),
                severity,
                3.0,
            ),
        ]),
    )
    t0 = day + Hour(15) + Minute(56)
    segments = Tuple{DateTime,DateTime}[]
    @test ChannelEffects.transfer_completion(outage(0.86), t0, 33.6, far; segments) ==
          day + Hour(16)
    @test segments == [(t0, day + Hour(16))]
    @test ChannelEffects.transfer_completion(outage(0.9), t0, 24.0, far) == day + Hour(16)
    # 0.1 s of work beyond the capacity of the pass waits for the next one,
    # at full capacity after the outage.
    @test ChannelEffects.transfer_completion(outage(0.86), t0, 33.7, far) ==
          day + Day(1) + Hour(8) + Millisecond(100)
    # Work below the tolerance still needs capacity. Started at the opening
    # of a pass that a full outage holds at zero, it completes at the
    # opening of the next pass, and no interval of the first is recorded as
    # transmitting.
    segments = Tuple{DateTime,DateTime}[]
    @test ChannelEffects.transfer_completion(
        outage(1.0),
        day + Hour(8),
        1e-10,
        far;
        segments,
    ) == day + Day(1) + Hour(8)
    @test all(s -> s[1] >= day + Day(1) + Hour(8), segments)
end

@testset "Transfer completion: merged windows" begin
    day = DateTime(2035, 1, 1)
    far = DateTime(2035, 2, 1)
    vis(schedule, low_latency) = TelemetryCore.VisibilityModel(
        Time(8),
        Second(8 * 3600),
        "flat",
        10.0,
        0.15,
        Second(0),
        365.25,
        172.0,
        Dict{Date,Tuple{Time,Second}}(),
        schedule,
        low_latency,
    )
    # Two abutting passes of an explicit schedule are one contact: a transfer
    # across their common edge runs on without a gap.
    abutting = vis(
        [
            TelemetryCore.ContactWindow(day + Hour(8), day + Hour(12)),
            TelemetryCore.ContactWindow(day + Hour(12), day + Hour(16)),
        ],
        TelemetryCore.ContactWindow[],
    )
    link = ChannelEffects.LinkModel(abutting)
    # Half-open windows: the common edge belongs to the second pass, the end
    # of the second to neither.
    @test TelemetryCore.active_window(abutting, day + Hour(12)).start == day + Hour(12)
    @test TelemetryCore.active_window(abutting, day + Hour(16)) === nothing
    @test ChannelEffects.transfer_completion(
        link,
        day + Hour(11) + Minute(59),
        120.0,
        far,
    ) == day + Hour(12) + Minute(1)
    # A daily 08:00–16:00 pass inside a low-latency period of half capacity,
    # 06:00–18:00: 30 s before the pass at 0.5 give 15 s, the remaining 30 s
    # run at full capacity; after the pass, the reverse.
    period = TelemetryCore.ContactWindow(day + Hour(6), day + Hour(18), 0.5, true, "test")
    link = ChannelEffects.LinkModel(vis(TelemetryCore.ContactWindow[], [period]))
    @test ChannelEffects.transfer_completion(
        link,
        day + Hour(7) + Minute(59) + Second(30),
        45.0,
        far,
    ) == day + Hour(8) + Second(30)
    @test ChannelEffects.transfer_completion(
        link,
        day + Hour(15) + Minute(59) + Second(30),
        45.0,
        far,
    ) == day + Hour(16) + Second(30)
end

@testset "Loss multiplier of a transfer" begin
    day = DateTime(2035, 1, 1)
    event = ChannelEffects.DisruptionEvent(
        "test",
        "",
        day + Hour(10),
        day + Hour(11),
        day + Hour(12),
        0.5,
        5.0,
    )
    tl = ChannelEffects.DisruptionTimeline([event])
    m(t0, t1) = ChannelEffects.disruption_loss_multiplier(tl, [(t0, t1)])
    @test m(day + Hour(9) + Minute(59), day + Hour(10) + Minute(1)) == 5.0
    @test m(day + Hour(11) + Minute(59), day + Hour(12) + Minute(5)) == 5.0
    @test m(day + Hour(9), day + Hour(9) + Minute(59)) == 1.0
    @test m(day + Hour(12), day + Hour(12) + Minute(5)) == 1.0
    # A transfer that completes as the event starts never ran under it.
    @test m(day + Hour(9), day + Hour(10)) == 1.0
    # An event confined to an interruption of the transfer, when it sent
    # nothing, does not count.
    @test ChannelEffects.disruption_loss_multiplier(
        tl,
        [
            (day + Hour(9), day + Hour(9) + Minute(30)),
            (day + Hour(13), day + Hour(13) + Minute(5)),
        ],
    ) == 1.0
end
