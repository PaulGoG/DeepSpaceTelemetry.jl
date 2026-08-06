module ChannelEffects

using ..TelemetryCore
using Dates
using Random

export LossModel,
    NoLoss,
    BernoulliLoss,
    GilbertElliottLoss,
    sample_loss!,
    stationary_loss_rate,
    DisruptionEvent,
    DisruptionTimeline,
    disruption_factor,
    disruption_loss_multiplier,
    active_disruption_label,
    LinkModel,
    effective_bandwidth,
    is_transmittable,
    build_loss_model,
    build_disruption_timeline,
    build_link_model,
    loss_retry_limit

# --- Stochastic Packet-Loss Models ---
"""
    LossModel

Abstract supertype for stochastic downlink packet-loss models. Concrete models
implement [`sample_loss!`](@ref), which is drawn once per batch transfer
attempt on the receiver side. All models carry their own seeded `Xoshiro` RNG
so loss realizations are reproducible independently of the physics stream.
"""
abstract type LossModel end

"""
    NoLoss()

The trivial loss model: every transfer attempt succeeds. Used when
`[packet_loss] enabled = false`.
"""
struct NoLoss <: LossModel end

"""
    BernoulliLoss(p, rng)

Memoryless i.i.d. packet loss: each batch transfer attempt fails independently
with probability `p ∈ [0, 1]`.
"""
mutable struct BernoulliLoss <: LossModel
    p::Float64
    rng::Random.AbstractRNG
end

"""
    GilbertElliottLoss(p_good_to_bad, p_bad_to_good, p_loss_good, p_loss_bad, in_bad_state, rng)

Two-state Markov (Gilbert–Elliott) bursty-channel model — the canonical model
for correlated packet loss. The channel alternates between a GOOD state with
loss probability `p_loss_good` and a BAD state with loss probability
`p_loss_bad`; state transitions occur once per transfer attempt with
probabilities `p_good_to_bad` / `p_bad_to_good`. All four parameters must lie
in `[0, 1]`.
"""
mutable struct GilbertElliottLoss <: LossModel
    p_good_to_bad::Float64
    p_bad_to_good::Float64
    p_loss_good::Float64
    p_loss_bad::Float64
    in_bad_state::Bool
    rng::Random.AbstractRNG
end

"""
    sample_loss!(model::LossModel; multiplier::Float64=1.0) -> Bool

Draws one loss realization for a single batch transfer attempt. Returns `true`
if the transfer is lost. `multiplier` scales the instantaneous loss
probability (clamped to `[0, 1]`) and is used to elevate loss rates during
disruption events (see [`disruption_loss_multiplier`](@ref)). Mutates internal
channel state for stateful models (Gilbert–Elliott).
"""
sample_loss!(::NoLoss; multiplier::Float64 = 1.0) = false

function sample_loss!(m::BernoulliLoss; multiplier::Float64 = 1.0)
    return rand(m.rng) < clamp(m.p * multiplier, 0.0, 1.0)
end

function sample_loss!(m::GilbertElliottLoss; multiplier::Float64 = 1.0)
    # Advance the channel state once per transfer attempt.
    if m.in_bad_state
        if rand(m.rng) < m.p_bad_to_good
            m.in_bad_state = false
        end
    else
        if rand(m.rng) < m.p_good_to_bad
            m.in_bad_state = true
        end
    end
    p = m.in_bad_state ? m.p_loss_bad : m.p_loss_good
    return rand(m.rng) < clamp(p * multiplier, 0.0, 1.0)
end

"""
    stationary_loss_rate(model::LossModel) -> Float64

Analytic long-run loss probability of the model (used for physics-style
validation of the sampled stream). For Gilbert–Elliott this is
`π_bad·p_loss_bad + π_good·p_loss_good` with the stationary state occupancies
`π_bad = p_g2b / (p_g2b + p_b2g)`.
"""
stationary_loss_rate(::NoLoss) = 0.0
stationary_loss_rate(m::BernoulliLoss) = m.p

function stationary_loss_rate(m::GilbertElliottLoss)
    denom = m.p_good_to_bad + m.p_bad_to_good
    denom == 0.0 && return m.in_bad_state ? m.p_loss_bad : m.p_loss_good
    pi_bad = m.p_good_to_bad / denom
    return pi_bad * m.p_loss_bad + (1.0 - pi_bad) * m.p_loss_good
end

# --- Disruption Events ---
"""
    DisruptionEvent

A scheduled link-degrading event (a solar flare, a spacecraft safe-mode entry,
a ground-station outage, …). Between `start_time` and `blackout_end` the link
capacity is multiplied by `1 - severity` (`severity = 1` is a full blackout);
between `blackout_end` and `recovery_end` capacity ramps linearly back to
nominal. Throughout the whole event (blackout + recovery) the stochastic loss
probability is scaled by `loss_multiplier`. `label` is an optional free-text
display name shown on the dashboard while the event is active.
"""
struct DisruptionEvent
    type::String
    label::String
    start_time::DateTime
    blackout_end::DateTime
    recovery_end::DateTime
    severity::Float64
    loss_multiplier::Float64
end

"""
    DisruptionTimeline(events::Vector{DisruptionEvent})

Chronologically sorted collection of [`DisruptionEvent`](@ref)s. Overlapping
events compose conservatively: the *minimum* capacity factor and the *maximum*
loss multiplier apply.
"""
struct DisruptionTimeline
    events::Vector{DisruptionEvent}
end

DisruptionTimeline() = DisruptionTimeline(DisruptionEvent[])

"""
    disruption_factor(tl::DisruptionTimeline, t::DateTime) -> Float64

Multiplicative link-capacity factor in `[0, 1]` at simulation time `t`:
`1.0` outside all events, `1 - severity` during a blackout, and a linear ramp
from `1 - severity` back to `1.0` during the recovery phase.
"""
function disruption_factor(tl::DisruptionTimeline, t::DateTime)
    f = 1.0
    for ev in tl.events
        if ev.start_time <= t < ev.blackout_end
            f = min(f, 1.0 - ev.severity)
        elseif ev.blackout_end <= t < ev.recovery_end
            total_ms = (ev.recovery_end - ev.blackout_end).value
            progress = total_ms == 0 ? 1.0 : (t - ev.blackout_end).value / total_ms
            f = min(f, (1.0 - ev.severity) + ev.severity * clamp(progress, 0.0, 1.0))
        end
    end
    return f
end

"""
    disruption_loss_multiplier(tl::DisruptionTimeline, t::DateTime) -> Float64

Multiplier (≥ 1) applied to the stochastic loss probability at time `t`.
Active from event start through the end of the recovery ramp.
"""
function disruption_loss_multiplier(tl::DisruptionTimeline, t::DateTime)
    m = 1.0
    for ev in tl.events
        if ev.start_time <= t < ev.recovery_end
            m = max(m, ev.loss_multiplier)
        end
    end
    return m
end

"""
    active_disruption_label(tl::DisruptionTimeline, t::DateTime) -> String

The `label` of the earliest-starting disruption event active at time `t` that
carries a non-empty label, or `""` when no active event is labeled. Used by
the dashboard status line to name the ongoing event.
"""
function active_disruption_label(tl::DisruptionTimeline, t::DateTime)
    for ev in tl.events
        if ev.start_time <= t < ev.recovery_end && !isempty(ev.label)
            return ev.label
        end
    end
    return ""
end

# --- Composite Link Model ---
"""
    LinkModel(visibility::TelemetryCore.VisibilityModel, disruptions::DisruptionTimeline)

The complete downlink channel: daily DSN visibility windows composed with the
disruption timeline. `LinkModel(vis)` builds a disruption-free link.
"""
struct LinkModel
    visibility::TelemetryCore.VisibilityModel
    disruptions::DisruptionTimeline
end

LinkModel(vis::TelemetryCore.VisibilityModel) = LinkModel(vis, DisruptionTimeline())

"""
    effective_bandwidth(link::LinkModel, t::DateTime) -> Float64

Effective link capacity in `[0, 1]` at simulation time `t`: the visibility
bandwidth profile multiplied by the disruption capacity factor.
"""
function effective_bandwidth(link::LinkModel, t::DateTime)
    return TelemetryCore.get_bandwidth_factor(link.visibility, t) *
           disruption_factor(link.disruptions, t)
end

"""
    is_transmittable(link::LinkModel, t::DateTime) -> Bool

Whether the satellite can place batches on the downlink at time `t`:
geometrically visible *and* not inside a full blackout.
"""
function is_transmittable(link::LinkModel, t::DateTime)
    return TelemetryCore.is_visible(link.visibility, t) &&
           disruption_factor(link.disruptions, t) > 0.0
end

# --- Config Builders ---
"""
    build_loss_model(cfg::AbstractDict, seed::Integer) -> LossModel

Constructs the stochastic loss model declared in the `[packet_loss]` config
section, with its own RNG seeded from `seed`. Returns [`NoLoss`](@ref) when
the section is absent or `enabled = false`. Errors on an unknown `model`
string or probabilities outside `[0, 1]` (validated upstream by
`TelemetryCore.validate_config`, re-checked here defensively).
"""
function build_loss_model(cfg::AbstractDict, seed::Integer)
    pl = get(cfg, "packet_loss", Dict{String,Any}())
    get(pl, "enabled", false) || return NoLoss()

    model = lowercase(
        TelemetryCore.checked_string(get(pl, "model", "bernoulli"), "packet_loss.model"),
    )
    rng = Xoshiro(seed)

    getp =
        key -> begin
            v = TelemetryCore.checked_number(get(pl, key, 0.0), "packet_loss.$key")
            0.0 <= v <= 1.0 || error("[CONFIG] packet_loss.$key = $v outside [0, 1].")
            v
        end

    if model == "bernoulli"
        p = TelemetryCore.checked_number(get(pl, "p_loss", 0.05), "packet_loss.p_loss")
        0.0 <= p <= 1.0 || error("[CONFIG] packet_loss.p_loss = $p outside [0, 1].")
        return BernoulliLoss(p, rng)
    elseif model == "gilbert_elliott"
        return GilbertElliottLoss(
            getp("p_good_to_bad"),
            getp("p_bad_to_good"),
            getp("p_loss_good"),
            getp("p_loss_bad"),
            false,
            rng,
        )
    else
        error(
            "[CONFIG] Unknown packet_loss.model = \"$model\" (expected \"bernoulli\" or \"gilbert_elliott\").",
        )
    end
end

"""
    loss_retry_limit(cfg::AbstractDict) -> Int

Resolves the retry policy from `[packet_loss]`: `on_loss = "drop"` maps to 0
retries (immediate loss), `"retransmit"` (default) to `max_retries`
(default 3).
"""
function loss_retry_limit(cfg::AbstractDict)
    pl = get(cfg, "packet_loss", Dict{String,Any}())
    on_loss = lowercase(
        TelemetryCore.checked_string(
            get(pl, "on_loss", "retransmit"),
            "packet_loss.on_loss",
        ),
    )
    on_loss in ("retransmit", "drop") || error(
        "[CONFIG] Unknown packet_loss.on_loss = \"$on_loss\" (expected \"retransmit\" or \"drop\").",
    )
    on_loss == "drop" && return 0
    retries =
        TelemetryCore.checked_integer(get(pl, "max_retries", 3), "packet_loss.max_retries")
    retries >= 0 || error("[CONFIG] packet_loss.max_retries must be ≥ 0 (got $retries).")
    return retries
end

"""
    build_disruption_timeline(cfg::AbstractDict, start_sim::DateTime) -> DisruptionTimeline

Constructs the disruption timeline from `[[disruption.events]]` (the legacy
`[[disaster.events]]` section name from pre-rename run snapshots is still
accepted). Event `start_day` values are mission days relative to `start_sim`.
Malformed events raise an error rather than being skipped: a silently missing
disruption invalidates the scenario.
"""
function build_disruption_timeline(cfg::AbstractDict, start_sim::DateTime)
    d = get(cfg, "disruption", get(cfg, "disaster", Dict{String,Any}()))
    raw_events = get(d, "events", Any[])
    events = DisruptionEvent[]
    for (i, e) in enumerate(raw_events)
        start_day = TelemetryCore.checked_number(
            get(e, "start_day", -1.0),
            "disruption.events[$i].start_day",
        )
        start_day >= 0.0 ||
            error("[CONFIG] disruption.events[$i].start_day must be ≥ 0 (got $start_day).")
        dur_h = TelemetryCore.checked_number(
            get(e, "duration_hours", 24.0),
            "disruption.events[$i].duration_hours",
        )
        dur_h > 0.0 ||
            error("[CONFIG] disruption.events[$i].duration_hours must be > 0 (got $dur_h).")
        rec_h = TelemetryCore.checked_number(
            get(e, "recovery_hours", 0.0),
            "disruption.events[$i].recovery_hours",
        )
        rec_h >= 0.0 ||
            error("[CONFIG] disruption.events[$i].recovery_hours must be ≥ 0 (got $rec_h).")
        sev = TelemetryCore.checked_number(
            get(e, "severity", 1.0),
            "disruption.events[$i].severity",
        )
        0.0 <= sev <= 1.0 ||
            error("[CONFIG] disruption.events[$i].severity = $sev outside [0, 1].")
        mult = TelemetryCore.checked_number(
            get(e, "loss_multiplier", 1.0),
            "disruption.events[$i].loss_multiplier",
        )
        mult >= 1.0 ||
            @warn "[CONFIG] disruption.events[$i].loss_multiplier < 1 reduces loss during the event."

        t0 = start_sim + Millisecond(round(Int, start_day * 86_400_000))
        t1 = t0 + Millisecond(round(Int, dur_h * 3_600_000))
        t2 = t1 + Millisecond(round(Int, rec_h * 3_600_000))
        push!(
            events,
            DisruptionEvent(
                TelemetryCore.checked_string(
                    get(e, "type", "link_disruption"),
                    "disruption.events[$i].type",
                ),
                TelemetryCore.checked_string(
                    get(e, "label", ""),
                    "disruption.events[$i].label",
                ),
                t0,
                t1,
                t2,
                sev,
                mult,
            ),
        )
    end
    sort!(events, by = ev -> ev.start_time)
    return DisruptionTimeline(events)
end

"""
    build_link_model(cfg::AbstractDict) -> LinkModel

Constructs the full [`LinkModel`](@ref) from a parsed configuration:
visibility from `[telemetry]`, disruptions from `[disruption]` anchored at
`simulation.start_sim_time`.
"""
function build_link_model(cfg::AbstractDict)
    vis = TelemetryCore.VisibilityModel(
        Time(cfg["telemetry"]["session_start"]),
        Second(round(Int, Float64(cfg["telemetry"]["session_duration_hours"]) * 3600)),
        String(get(cfg["telemetry"], "bandwidth_profile", "sine")),
    )
    start_sim = DateTime(cfg["simulation"]["start_sim_time"])
    return LinkModel(vis, build_disruption_timeline(cfg, start_sim))
end

end # module ChannelEffects
