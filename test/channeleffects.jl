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

    # The retired [disaster] section name is rejected, not read through a fallback.
    legacy = Dict{String,Any}(
        "disaster" => Dict{String,Any}(
            "events" =>
                [Dict{String,Any}("start_day" => 0.0, "duration_hours" => 12.0)],
        ),
    )
    @test_throws ArgumentError ChannelEffects.build_disruption_timeline(legacy, start)

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
