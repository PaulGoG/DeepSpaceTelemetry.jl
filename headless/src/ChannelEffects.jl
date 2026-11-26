"""
    ChannelEffects

Downlink channel models: stochastic packet loss (`NoLoss`, `BernoulliLoss`,
two-state `GilbertElliottLoss` with its analytic stationary rate), scheduled
disruption events (blackout, linear recovery ramp, elevated loss), and the
composite `LinkModel` (visibility × disruption) gating both pipeline loops.
"""
module ChannelEffects

using ..TelemetryCore: TelemetryCore
using Dates: Dates, DateTime, Day, Millisecond
using Random: Random, Xoshiro

# --- Stochastic Packet-Loss Models ---
"""
    LossModel

Abstract supertype for stochastic downlink packet-loss models. Concrete models
implement [`sample_loss!`](@ref), which is drawn once per batch transfer
attempt on the receiver side. The random models carry their own RNG, a
`Xoshiro` seeded by [`build_loss_model`](@ref): the variates of the `k`-th
attempt depend on the seed alone.
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
struct BernoulliLoss{R<:Random.AbstractRNG} <: LossModel
    p::Float64
    rng::R
end

"""
    GilbertElliottLoss(p_good_to_bad, p_bad_to_good, p_loss_good, p_loss_bad, in_bad_state, rng)

Two-state Markov (Gilbert–Elliott) bursty-channel model of correlated packet
loss (Gilbert 1960, doi:10.1002/j.1538-7305.1960.tb03959.x; Elliott 1963,
doi:10.1002/j.1538-7305.1963.tb00955.x). The channel alternates between a
GOOD state with loss probability `p_loss_good` and a BAD state with loss
probability `p_loss_bad`; state transitions occur once per transfer attempt
with probabilities `p_good_to_bad` / `p_bad_to_good`. All four parameters
must lie in `[0, 1]`.
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
`π_bad = p_good_to_bad / (p_good_to_bad + p_bad_to_good)`.

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

stationary_loss_rate(m::GilbertElliottLoss) = TelemetryCore.gilbert_elliott_loss_rate(
    m.p_good_to_bad,
    m.p_bad_to_good,
    m.p_loss_good,
    m.p_loss_bad;
    in_bad_state = m.in_bad_state,
)

# --- Disruption Events ---
"""
    DisruptionEvent

A scheduled link-degrading event (a spacecraft safe mode after a solar
particle event, a ground-station outage, …). Between `start_time` and `blackout_end` the link
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
loss multiplier apply. `DisruptionTimeline()` builds the empty timeline of a
disruption-free link.
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
    disruption_loss_multiplier(tl::DisruptionTimeline, segments::AbstractVector{Tuple{DateTime,DateTime}}) -> Float64

The largest loss multiplier (≥ 1) of the events active at some instant of
the intervals `[a, b)` in `segments`: the multiplier of a transfer that
transmitted during them ([`transfer_completion`](@ref) records them). An
event confined to an interruption of the transfer, when no frame is sent,
does not count.
"""
function disruption_loss_multiplier(
    tl::DisruptionTimeline,
    segments::AbstractVector{Tuple{DateTime,DateTime}},
)
    m = 1.0
    for ev in tl.events, (a, b) in segments
        if ev.start_time < b && a < ev.recovery_end
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

"""
    WORK_TOLERANCE_SEC

Work below which a transfer counts as complete in
[`transfer_completion`](@ref): 1 ns of full-capacity transfer. The remaining
work accumulates rounding of the order of 10⁻¹³ s over the steps of a
transfer, and the completion instants live on the millisecond grid. The
work it leaves undone lasts at most 10⁻⁹/c seconds at capacity `c`, below
the millisecond above `c = 10⁻⁶`; under a disruption of severity above
1 − 10⁻⁶ a transfer can complete that much earlier. When the work left
exceeds the capacity of a step by less than the tolerance, the transfer
completes inside that step, at the instant of the linear interpolant,
rather than at its end; the two instants differ by the discretization
error of the step.
"""
const WORK_TOLERANCE_SEC = 1e-9

"""
    transfer_completion(link::LinkModel, t0::DateTime, work_sec::Real,
                        horizon::DateTime; step_sec::Real = 60.0, segments = nothing)
        -> Union{DateTime,Nothing}

The instant at which a transfer that starts at `t0` and needs `work_sec`
seconds at full capacity completes: the first `τ` with
`∫_{t0}^{τ} c(t) dt = work_sec`, `c` the effective capacity
([`effective_bandwidth`](@ref)), which is zero outside the contact windows.
A transfer interrupted by the end of a contact or by a blackout resumes at
the next contact. The integral is evaluated by the midpoint rule on
sub-intervals of at most `step_sec` seconds, split at the window boundaries
and at the breakpoints of the disruption timeline so that the capacity is
smooth on each; within the sub-interval that completes the transfer the
capacity is interpolated linearly between its ends and the integral solved
for `τ` ([`linear_fill_time`](@ref)). Exact for a capacity that is
piecewise linear between the breakpoints, second order in `step_sec`
otherwise. A step of positive capacity completes the transfer when the work
left after it is within [`WORK_TOLERANCE_SEC`](@ref), so a transfer whose
work equals the capacity left in a contact window completes at the end of
that window and not, on a rounding residual, at the opening of the next.
Returns `nothing` when the
transfer does not complete before `horizon`; the result is rounded to the
millisecond. With a vector `segments`, the intervals during which the
transfer transmitted (positive capacity) are appended to it, abutting ones
joined, for [`disruption_loss_multiplier`](@ref).
"""
function transfer_completion(
    link::LinkModel,
    t0::DateTime,
    work_sec::Real,
    horizon::DateTime;
    step_sec::Real = 60.0,
    segments::Union{Nothing,Vector{Tuple{DateTime,DateTime}}} = nothing,
)
    work_sec > 0 ||
        throw(ArgumentError("[LINK] A transfer needs work_sec > 0 (got $work_sec)."))
    step_sec >= 0.001 || throw(
        ArgumentError("[LINK] The integration step must be >= 0.001 s (got $step_sec)."),
    )
    remaining = Float64(work_sec)
    breaks = disruption_breakpoints(link.disruptions)
    t = t0
    lookahead = Day(2)
    while t < horizon
        chunk_end = min(horizon, t + lookahead)
        windows = TelemetryCore.contact_windows(link.visibility, t, chunk_end)
        # The capacity also changes form at the edges of a window merged
        # into another (a pass inside a low-latency period).
        edges = sort!(vcat(breaks, DateTime[x for w in windows for x in (w.start, w.stop)]))
        for (a, b) in merged_intervals(windows)
            b <= t && continue
            a >= chunk_end && break
            lo = max(a, t)
            hi = min(b, chunk_end)
            while lo < hi
                next_break = first_break_after(edges, lo)
                stop = min(hi, lo + Millisecond(round(Int, step_sec * 1000)), next_break)
                h = (stop - lo).value / 1000
                c = effective_bandwidth(link, lo + Millisecond(round(Int, 500 * h)))
                if c > 0 && c * h >= remaining - WORK_TOLERANCE_SEC
                    # The capacity at both ends of the completing step, the
                    # far end extrapolated from 1 ms inside it (the window
                    # or the event phase may end there).
                    c0 = effective_bandwidth(link, lo)
                    inner = effective_bandwidth(link, stop - Millisecond(1))
                    c1 = h > 0.001 ? c0 + (inner - c0) * h / (h - 0.001) : c
                    x = linear_fill_time(c0, c1, h, remaining)
                    done = lo + Millisecond(round(Int, 1000 * x))
                    record_segment!(segments, lo, done)
                    return done < horizon ? done : nothing
                end
                c > 0 && record_segment!(segments, lo, stop)
                remaining -= c * h
                lo = stop
            end
        end
        t = chunk_end
    end
    return nothing
end

"""
    linear_fill_time(c0::Float64, c1::Float64, h::Float64, r::Float64) -> Float64

The time `x ∈ (0, h]` at which a capacity interpolated linearly from `c0`
at the start of a step of `h` seconds to `c1` at its end has delivered `r`
seconds of full-capacity transfer: `c0·x + (c1 − c0)·x²/(2h) = r`, solved
as `x = 2r / (c0 + √(c0² + 2r(c1 − c0)/h))`, which stays accurate when
`c1 ≈ c0` and is exact for a linear capacity. `h` when the interpolant does
not reach `r` within the step.
"""
function linear_fill_time(c0::Float64, c1::Float64, h::Float64, r::Float64)
    discriminant = c0^2 + 2r * (c1 - c0) / h
    discriminant < 0 && return h
    denominator = c0 + sqrt(discriminant)
    denominator > 0 || return h
    return min(h, 2r / denominator)
end

# Appends the transmitting interval [a, b) to `segments`, extending the last
# one when they abut; nothing without a vector.
record_segment!(::Nothing, a::DateTime, b::DateTime) = nothing
function record_segment!(
    segments::Vector{Tuple{DateTime,DateTime}},
    a::DateTime,
    b::DateTime,
)
    if !isempty(segments) && segments[end][2] == a
        segments[end] = (segments[end][1], b)
    else
        push!(segments, (a, b))
    end
    return nothing
end

# The contact windows as disjoint intervals [start, stop), overlapping or
# abutting windows merged; `windows` is sorted by start.
function merged_intervals(windows)
    merged = Tuple{DateTime,DateTime}[]
    for w in windows
        w.stop > w.start || continue
        if !isempty(merged) && w.start <= merged[end][2]
            merged[end] = (merged[end][1], max(merged[end][2], w.stop))
        else
            push!(merged, (w.start, w.stop))
        end
    end
    return merged
end

# The instants at which the disruption factor changes form: event starts,
# blackout ends, recovery ends; sorted and unique.
disruption_breakpoints(tl::DisruptionTimeline) = sort!(
    unique!(
        DateTime[
            t for ev in tl.events for t in (ev.start_time, ev.blackout_end, ev.recovery_end)
        ],
    ),
)

# The first breakpoint strictly after `t`, or `typemax(DateTime)`.
function first_break_after(breaks::Vector{DateTime}, t::DateTime)
    i = searchsortedfirst(breaks, t + Millisecond(1))
    return i <= length(breaks) ? breaks[i] : typemax(DateTime)
end

# --- Config Builders ---
"""
    build_loss_model(cfg::AbstractDict, seed::Integer) -> LossModel

Constructs the stochastic loss model declared in the `[packet_loss]` config
section, with its own RNG seeded from `seed`. Returns [`NoLoss`](@ref) when
the section is absent or `enabled = false`. An unknown `model` string or a
probability outside `[0, 1]` raises the `[CONFIG]` error of
`TelemetryCore.loss_channel_settings` (validated upstream by
`TelemetryCore.validate_config` as well).
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
[`TelemetryCore.disruption_event_settings`](@ref); events with
`affects = "generation"` belong to [`generation_gaps`](@ref) instead. Event
`start_day` values are mission days relative to `start_sim`.
"""
function build_disruption_timeline(cfg::AbstractDict, start_sim::DateTime)
    events = DisruptionEvent[]
    for ev in TelemetryCore.disruption_event_settings(cfg)
        ev.affects == "link" || continue
        t0 = start_sim + Millisecond(round(Int, ev.start_day * TelemetryCore.MS_PER_DAY))
        t1 = t0 + Millisecond(round(Int, ev.duration_hours * TelemetryCore.MS_PER_HOUR))
        t2 = t1 + Millisecond(round(Int, ev.recovery_hours * TelemetryCore.MS_PER_HOUR))
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
        t0 = start_sim + Millisecond(round(Int, ev.start_day * TelemetryCore.MS_PER_DAY))
        push!(
            gaps,
            (
                t0,
                t0 + Millisecond(round(Int, ev.duration_hours * TelemetryCore.MS_PER_HOUR)),
            ),
        )
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
    return LinkModel(
        TelemetryCore.visibility_model(cfg),
        build_disruption_timeline(cfg, TelemetryCore.mission_epoch(cfg)),
    )
end

end # module ChannelEffects
