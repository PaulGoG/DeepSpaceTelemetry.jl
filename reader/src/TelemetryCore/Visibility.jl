# --- Contact windows, visibility & bandwidth ---
"""
    BANDWIDTH_PROFILES

Capacity profiles of a nominal pass accepted in `telemetry.bandwidth_profile`
and by [`VisibilityModel`](@ref); [`profile_factor`](@ref) defines each.
"""
const BANDWIDTH_PROFILES = ("sine", "sigmoid", "gaussian", "flat")

"""
    VisibilityModel

Ground-contact model of the downlink. The nominal daily window opens at
`session_start` for `session_duration` with the capacity `profile` (one of
[`BANDWIDTH_PROFILES`](@ref), shaped by `sigmoid_steepness` or
`gaussian_sigma`; any other is an `ArgumentError`). `seasonal_extension`
widens it symmetrically about its center, cosine-modulated with period
`season_period_days` and peaking at `season_peak_day_of_year`. `exceptions`
(`date => (start, duration)`, zero duration for a missed pass) replace the
window of a date verbatim, and a non-empty `schedule` of explicit passes
replaces the daily generator. `low_latency` periods are additional windows
at constant capacity outside the nominal passes. The three- to
five-argument constructors build the plain daily model.

# Examples
```jldoctest
julia> model = TelemetryCore.VisibilityModel(Time(8), Second(8 * 3600), "sine");

julia> TelemetryCore.is_visible(model, DateTime(2035, 1, 1, 10)), TelemetryCore.is_visible(model, DateTime(2035, 1, 1, 3))
(true, false)

julia> round(TelemetryCore.profile_mean(model); digits = 3)
0.5
```
"""
struct VisibilityModel
    session_start::Time
    session_duration::Second
    profile::String
    sigmoid_steepness::Float64
    gaussian_sigma::Float64
    seasonal_extension::Second
    season_period_days::Float64
    season_peak_day_of_year::Float64
    exceptions::Dict{Date,Tuple{Time,Second}}
    schedule::Vector{ContactWindow}
    low_latency::Vector{ContactWindow}
    function VisibilityModel(
        session_start::Time,
        session_duration::Second,
        profile::String,
        sigmoid_steepness::Float64,
        gaussian_sigma::Float64,
        seasonal_extension::Second,
        season_period_days::Float64,
        season_peak_day_of_year::Float64,
        exceptions::Dict{Date,Tuple{Time,Second}},
        schedule::Vector{ContactWindow},
        low_latency::Vector{ContactWindow},
    )
        profile in BANDWIDTH_PROFILES || throw(
            ArgumentError(
                "Unknown capacity profile \"$profile\" (expected one of $(join(repr.(BANDWIDTH_PROFILES), ", "))).",
            ),
        )
        return new(
            session_start,
            session_duration,
            profile,
            sigmoid_steepness,
            gaussian_sigma,
            seasonal_extension,
            season_period_days,
            season_peak_day_of_year,
            exceptions,
            schedule,
            low_latency,
        )
    end
end

function VisibilityModel(
    session_start::Time,
    session_duration::Second,
    profile::String,
    sigmoid_steepness::Float64 = 10.0,
    gaussian_sigma::Float64 = 0.15,
)
    return VisibilityModel(
        session_start,
        session_duration,
        profile,
        sigmoid_steepness,
        gaussian_sigma,
        Second(0),
        365.25,
        172.0,
        Dict{Date,Tuple{Time,Second}}(),
        ContactWindow[],
        ContactWindow[],
    )
end

"""
    seasonal_window_duration(model::VisibilityModel, date::Date) -> Second

Duration of the generated window on `date`: `session_duration` plus the
seasonal extension modulated as `½ [1 + cos(2π (d − d_peak) / P)]` with the
day of year `d`, so the full extension applies at `season_peak_day_of_year`
and none half a period away.
"""
function seasonal_window_duration(model::VisibilityModel, date::Date)
    model.seasonal_extension.value == 0 && return model.session_duration
    phase =
        2π * (Dates.dayofyear(date) - model.season_peak_day_of_year) /
        model.season_period_days
    extension = 0.5 * (1 + cos(phase)) * model.seasonal_extension.value
    return model.session_duration + Second(round(Int, extension))
end

"""
    nominal_window(model::VisibilityModel, date::Date) -> Union{Nothing,ContactWindow}

The nominal pass anchored on `date` under the daily generator: the
exception of that date verbatim when one exists (`nothing` for a missed
pass), otherwise the configured window extended symmetrically by the
seasonal term. `nothing` in explicit-schedule mode.
"""
function nominal_window(model::VisibilityModel, date::Date)
    isempty(model.schedule) || return nothing
    if haskey(model.exceptions, date)
        start_time, duration = model.exceptions[date]
        duration.value > 0 || return nothing
        start = DateTime(date, start_time)
        return ContactWindow(start, start + duration)
    end
    extension = seasonal_window_duration(model, date) - model.session_duration
    half = Millisecond(round(Int, 500 * extension.value))
    start = DateTime(date, model.session_start) - half
    return ContactWindow(start, start + model.session_duration + 2 * half)
end

"""
    contact_windows(model::VisibilityModel, t_lo::DateTime, t_hi::DateTime) -> Vector{ContactWindow}

Every contact window — nominal passes and low-latency periods — that
overlaps `[t_lo, t_hi]`, sorted by start.
"""
function contact_windows(model::VisibilityModel, t_lo::DateTime, t_hi::DateTime)
    windows = ContactWindow[]
    if isempty(model.schedule)
        for date in (Date(t_lo)-Day(1)):Day(1):Date(t_hi)
            w = nominal_window(model, date)
            w === nothing || push!(windows, w)
        end
    else
        append!(windows, model.schedule)
    end
    append!(windows, model.low_latency)
    filter!(w -> w.stop >= t_lo && w.start <= t_hi, windows)
    return sort!(windows; by = w -> w.start)
end

"""
    active_window(model::VisibilityModel, t::DateTime) -> Union{Nothing,ContactWindow}

The contact window containing `t` — a nominal pass first, else a
low-latency period — or `nothing` when the spacecraft is out of contact.
Under the daily generator only the windows anchored on the date of `t`
and on the previous date (a pass crossing midnight) can contain `t`.
"""
function active_window(model::VisibilityModel, t::DateTime)
    if isempty(model.schedule)
        date = Date(t)
        for d in (date, date - Day(1))
            w = nominal_window(model, d)
            w !== nothing && w.start <= t <= w.stop && return w
        end
    else
        for w in model.schedule
            w.start > t && break
            t <= w.stop && return w
        end
    end
    for w in model.low_latency
        w.start > t && break
        t <= w.stop && return w
    end
    return nothing
end

"""
    is_visible(model::VisibilityModel, t::DateTime) -> Bool

Whether the spacecraft is in ground contact at `t` — inside a nominal pass
or a low-latency period ([`active_window`](@ref)).
"""
is_visible(model::VisibilityModel, t::DateTime) = active_window(model, t) !== nothing

"""
    profile_factor(model::VisibilityModel, progress::Float64) -> Float64

The capacity profile of a nominal pass at the normalized position
`progress ∈ [0, 1]` within the window: `sin²(π p)` for `sine`,
`[tanh(k p) + tanh(k (1 − p))] / 2` for `sigmoid`,
`exp(−(p − ½)² / (2σ²))` for `gaussian`, and `1` for `flat`.
"""
function profile_factor(model::VisibilityModel, progress::Float64)
    if model.profile == "sine"
        return sin(pi * progress)^2
    elseif model.profile == "sigmoid"
        k = model.sigmoid_steepness
        return (tanh(k * progress) + tanh(k * (1 - progress))) / 2.0
    elseif model.profile == "gaussian"
        return exp(-((progress - 0.5)^2) / (2 * model.gaussian_sigma^2))
    elseif model.profile == "flat"
        return 1.0
    else
        throw(ArgumentError("Unknown capacity profile \"$(model.profile)\"."))
    end
end

# Composite-Simpson subintervals of profile_mean: 10⁻¹⁰ accuracy on the shipped
# profiles at negligible cost (one evaluation per validation and banner).
const PROFILE_MEAN_SUBINTERVALS = 1024

"""
    profile_mean(model::VisibilityModel) -> Float64

Mean of the capacity profile over one nominal pass,
`∫₀¹ profile_factor(model, p) dp`, by composite Simpson quadrature on
`PROFILE_MEAN_SUBINTERVALS`: `1` for `flat`, `1/2` for `sine`, `ln(cosh k)/k`
for `sigmoid` with steepness `k`, and `σ √(2π) erf(1/(2√2 σ))` for
`gaussian`. Multiplied by the full-capacity rate and the pass length it
gives the capacity of one pass in batches ([`capacity_balance`](@ref)).
"""
function profile_mean(model::VisibilityModel)
    n = PROFILE_MEAN_SUBINTERVALS
    h = 1.0 / n
    acc = profile_factor(model, 0.0) + profile_factor(model, 1.0)
    for i in 1:(n-1)
        acc += (isodd(i) ? 4.0 : 2.0) * profile_factor(model, i * h)
    end
    return acc * h / 3.0
end

"""
    get_bandwidth_factor(model::VisibilityModel, t::DateTime) -> Float64

Effective link capacity in `[0, 1]` at `t`: the pass profile evaluated at
the position of `t` within the active nominal window, the constant
capacity fraction inside a low-latency period, and `0` out of contact.

# Examples
```jldoctest
julia> model = TelemetryCore.VisibilityModel(Time(8), Second(8 * 3600), "sine");

julia> TelemetryCore.get_bandwidth_factor(model, DateTime(2035, 1, 1, 12))
1.0

julia> TelemetryCore.get_bandwidth_factor(model, DateTime(2035, 1, 1, 8))
0.0

julia> TelemetryCore.get_bandwidth_factor(model, DateTime(2035, 1, 1, 20))
0.0
```
"""
function get_bandwidth_factor(model::VisibilityModel, t::DateTime)
    w = active_window(model, t)
    w === nothing && return 0.0
    w.low_latency && return w.capacity
    total_ms = (w.stop - w.start).value
    progress = total_ms == 0 ? 1.0 : clamp((t - w.start).value / total_ms, 0.0, 1.0)
    return w.capacity * profile_factor(model, progress)
end
