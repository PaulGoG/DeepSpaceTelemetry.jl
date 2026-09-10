"""
    ChannelEffects

Downlink channel models: stochastic packet loss (`NoLoss`, `BernoulliLoss`,
two-state `GilbertElliottLoss` with its analytic stationary rate), scheduled
disruption events (blackout, linear recovery ramp, elevated loss), and the
composite `LinkModel` (visibility × disruption) gating both pipeline loops.
"""
module ChannelEffects

using ..TelemetryCore
using Dates: Dates, DateTime, Millisecond
using Random: Random, Xoshiro

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
with probability `p ∈ [0, 1]`. The RNG type is a struct parameter so the
per-attempt draw dispatches statically.
"""
struct BernoulliLoss{R<:Random.AbstractRNG} <: LossModel
    p::Float64
    rng::R
end

"""
    GilbertElliottLoss(p_good_to_bad, p_bad_to_good, p_loss_good, p_loss_bad, in_bad_state, rng)

Two-state Markov (Gilbert–Elliott) bursty-channel model — the canonical model
for correlated packet loss. The channel alternates between a GOOD state with
loss probability `p_loss_good` and a BAD state with loss probability
`p_loss_bad`; state transitions occur once per transfer attempt with
probabilities `p_good_to_bad` / `p_bad_to_good`. All four parameters must lie
in `[0, 1]`. The RNG type is a struct parameter so the per-attempt draws
dispatch statically.
"""
mutable struct GilbertElliottLoss{R<:Random.AbstractRNG} <: LossModel
    p_good_to_bad::Float64
    p_bad_to_good::Float64
    p_loss_good::Float64
    p_loss_bad::Float64
    in_bad_state::Bool
    rng::R
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

# Examples
```jldoctest
julia> ChannelEffects.stationary_loss_rate(ChannelEffects.BernoulliLoss(0.1, Xoshiro(1)))
0.1

julia> ge = ChannelEffects.GilbertElliottLoss(0.03, 0.25, 0.01, 0.5, false, Xoshiro(1));

julia> round(ChannelEffects.stationary_loss_rate(ge); digits = 4)
0.0625
```
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

# Examples
```jldoctest
julia> cfg = Dict{String,Any}(
           "disruption" => Dict{String,Any}(
               "events" => [Dict{String,Any}(
                   "start_day" => 2.0,
                   "duration_hours" => 12.0,
                   "recovery_hours" => 6.0,
                   "severity" => 1.0,
                   "loss_multiplier" => 4.0,
               )],
           ),
       );

julia> tl = ChannelEffects.build_disruption_timeline(cfg, DateTime(2035, 1, 1));

julia> ChannelEffects.disruption_loss_multiplier(tl, DateTime(2035, 1, 3, 6))
4.0

julia> ChannelEffects.disruption_loss_multiplier(tl, DateTime(2035, 1, 4))
1.0
```
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
    loss = TelemetryCore.loss_channel_settings(cfg)
    loss.enabled || return NoLoss()
    rng = Xoshiro(seed)
    loss.model == "bernoulli" && return BernoulliLoss(loss.p_loss, rng)
    return GilbertElliottLoss(
        loss.p_good_to_bad,
        loss.p_bad_to_good,
        loss.p_loss_good,
        loss.p_loss_bad,
        false,
        rng,
    )
end

"""
    loss_retry_limit(cfg::AbstractDict) -> Int

Resolves the retry policy from `[packet_loss]`: `on_loss = "drop"` maps to 0
retries (immediate loss), `"retransmit"` (default) to `max_retries`
(default 3).
"""
function loss_retry_limit(cfg::AbstractDict)
    loss = TelemetryCore.loss_channel_settings(cfg)
    return loss.on_loss == "drop" ? 0 : loss.max_retries
end

"""
    build_disruption_timeline(cfg::AbstractDict, start_sim::DateTime) -> DisruptionTimeline

Constructs the link-disruption timeline from the validated
[`TelemetryCore.disruption_event_settings`](@ref) (the legacy
`[[disaster.events]]` section name is accepted); events with
`affects = "generation"` belong to [`generation_gaps`](@ref) instead. Event
`start_day` values are mission days relative to `start_sim`.
"""
function build_disruption_timeline(cfg::AbstractDict, start_sim::DateTime)
    events = DisruptionEvent[]
    for ev in TelemetryCore.disruption_event_settings(cfg)
        ev.affects == "link" || continue
        t0 = start_sim + Millisecond(round(Int, ev.start_day * 86_400_000))
        t1 = t0 + Millisecond(round(Int, ev.duration_hours * 3_600_000))
        t2 = t1 + Millisecond(round(Int, ev.recovery_hours * 3_600_000))
        push!(
            events,
            DisruptionEvent(ev.type, ev.label, t0, t1, t2, ev.severity, ev.loss_multiplier),
        )
    end
    sort!(events, by = ev -> ev.start_time)
    return DisruptionTimeline(events)
end

"""
    generation_gaps(cfg::AbstractDict, start_sim::DateTime) -> Vector{Tuple{DateTime,DateTime}}

The scheduled generation gaps — `[[disruption.events]]` with
`affects = "generation"` — as `(start, stop)` intervals of `duration_hours`
from `start_day`, sorted by start. The emitter produces no data inside
them (`Emitter.skip_generation_gaps!`).
"""
function generation_gaps(cfg::AbstractDict, start_sim::DateTime)
    gaps = Tuple{DateTime,DateTime}[]
    for ev in TelemetryCore.disruption_event_settings(cfg)
        ev.affects == "generation" || continue
        t0 = start_sim + Millisecond(round(Int, ev.start_day * 86_400_000))
        push!(gaps, (t0, t0 + Millisecond(round(Int, ev.duration_hours * 3_600_000))))
    end
    return sort!(gaps; by = first)
end

"""
    build_link_model(cfg::AbstractDict) -> LinkModel

Constructs the full [`LinkModel`](@ref) from a parsed configuration:
visibility from [`TelemetryCore.visibility_model`](@ref), disruptions from
`[disruption]` anchored at `simulation.start_sim_time`.
"""
function build_link_model(cfg::AbstractDict)
    start_sim = DateTime(cfg["simulation"]["start_sim_time"])
    return LinkModel(
        TelemetryCore.visibility_model(cfg),
        build_disruption_timeline(cfg, start_sim),
    )
end

end # module ChannelEffects
