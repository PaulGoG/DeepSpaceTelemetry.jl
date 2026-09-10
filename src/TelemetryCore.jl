"""
    TelemetryCore

Shared infrastructure of the simulation: configuration loading, schema-aware
validation, storage governance (artifact estimation, budgets, retention
settings), the accelerated mission clock and its persisted anchor, run
provenance (event logs, snapshots, `safesave` rotation), and batch/segment
I/O. Contains no routing logic — the queuing doctrine lives in `Emitter`
and `Receiver`.
"""
module TelemetryCore

using CSV: CSV
using DataFrames: DataFrames, DataFrame
using Dates: Dates, Date, DateTime, Day, Millisecond, Second, Time, now
using JSON3: JSON3
using LinearAlgebra: LinearAlgebra
using TOML: TOML

# --- Constants ---
"""
    L_ARM

Length of the LISA constellation arms [m]: 2.5e9 m (2.5 million km).
"""
const L_ARM = 2.5e9

"""
    C_LIGHT

Speed of light in vacuum (m/s).
"""
const C_LIGHT = 2.99792458e8

"""
    F_STAR

Characteristic transfer frequency of the LISA arm (Hz).
"""
const F_STAR = C_LIGHT / (2π * L_ARM)

# Source-anchored package root: @__DIR__ is stable across precompilation and
# relocation. (The previous DrWatson.projectdir() resolution was evaluated at
# precompile time and baked whichever environment precompiled last into the
# cache — docs/ or test/ paths could silently become the data root.)
const PROJECT_ROOT = abspath(joinpath(@__DIR__, ".."))

"""
    DATA_ROOT

Base directory for run storage (a `Ref`; default `<PROJECT_ROOT>/data`).
Every run-directory path resolves through [`run_directory`](@ref); tests and
embedding applications may redirect it (e.g. to a temporary directory).
"""
const DATA_ROOT = Ref{String}("")

function __init__()
    # Runtime (not precompile-time) initialization; tests and embedding
    # applications may redirect after loading.
    DATA_ROOT[] = joinpath(PROJECT_ROOT, "data")
    return nothing
end

"""
    run_directory(run_id::String) -> String

Canonical run-directory path `<DATA_ROOT>/runs/<run_id>` — the single source
of the run layout for components, scripts, and post-processing tools.
"""
run_directory(run_id::String) = joinpath(runs_root(), run_id)

"""
    runs_root() -> String

Directory holding every run directory (`<DATA_ROOT>/runs`).
"""
runs_root() = joinpath(DATA_ROOT[], "runs")

"""
    latest_run_id() -> Union{Nothing, String}

ID of the most recently modified run directory under [`runs_root`](@ref) that
carries a `config_snapshot.toml`, or `nothing` when no run exists. Used by
the post-processing scripts when no run ID is given on the command line.
"""
function latest_run_id()
    root = runs_root()
    isdir(root) || return nothing
    runs = filter(readdir(root)) do name
        isfile(joinpath(root, name, "config_snapshot.toml"))
    end
    isempty(runs) && return nothing
    return last(sort(runs; by = name -> mtime(joinpath(root, name))))
end

# --- Batch wire format ---
# The on-disk batch naming is an interface shared by both components, the
# post-processing replay, and the terminal viewer; these helpers are its
# single definition.

"""
    batch_name(id::Integer, live::Bool) -> String

Directory name of batch `id`: `LIVE_batch_<id>` for a batch finalized while
the link was transmittable, `ARCH_batch_<id>` otherwise.

# Examples
```jldoctest
julia> TelemetryCore.batch_name(42, true)
"LIVE_batch_42"

julia> TelemetryCore.batch_name(42, false)
"ARCH_batch_42"
```
"""
batch_name(id::Integer, live::Bool) = string(live ? "LIVE_batch_" : "ARCH_batch_", id)

"""
    batch_id(name::AbstractString) -> Int

Numeric ID parsed from a batch directory name (the trailing `_<id>` field);
`0` for a name that does not carry one, so directory sweeps tolerate stray
entries instead of throwing.

# Examples
```jldoctest
julia> TelemetryCore.batch_id("LIVE_batch_42")
42

julia> TelemetryCore.batch_id("stray_entry")
0
```
"""
batch_id(name::AbstractString) = something(tryparse(Int, String(last(split(name, '_')))), 0)

"""
    is_live_batch(name::AbstractString) -> Bool

`true` for a `LIVE_batch_<id>` directory name (finalized while the link was
transmittable).

# Examples
```jldoctest
julia> TelemetryCore.is_live_batch("LIVE_batch_7"), TelemetryCore.is_live_batch("ARCH_batch_7")
(true, false)
```
"""
is_live_batch(name::AbstractString) = startswith(name, "LIVE_batch_")

"""
    is_archive_batch(name::AbstractString) -> Bool

`true` for an `ARCH_batch_<id>` directory name (blind-spot or blackout
generation, delivered by the LIFO backfill).
"""
is_archive_batch(name::AbstractString) = startswith(name, "ARCH_batch_")

"""
    is_batch_name(name::AbstractString) -> Bool

`true` for either batch class; `false` for any other directory entry.
"""
is_batch_name(name::AbstractString) = is_live_batch(name) || is_archive_batch(name)

# --- Configuration Management ---
"""
    load_config(path::String="")

Loads the mission configuration from `config.toml`. Uses the provided path
(relative paths resolve against the current directory first, then the project
root) or defaults to `config.toml` at the project root.
"""
function load_config(path::String = "")
    if isempty(path)
        path = isfile("config.toml") ? "config.toml" : joinpath(PROJECT_ROOT, "config.toml")
    elseif !isabspath(path) && !isfile(path)
        # Relative config paths resolve against the project root when not
        # found in the CWD (same rule as physics.external_data_path), so
        # `run_full_sim.jl scenario.toml` works from any directory.
        candidate = joinpath(PROJECT_ROOT, path)
        isfile(candidate) && (path = candidate)
    end
    if !isfile(path)
        error("Configuration file not found at $path")
    end
    try
        return TOML.parsefile(path)
    catch e
        error("[CONFIG] Failed to parse $path as TOML: $(sprint(showerror, e))")
    end
end

"""
    load_run_config(run_dir::String)

Loads the configuration that produced a given run: the run's own
`config_snapshot.toml` when present, falling back to the project-level
`config.toml` for legacy runs. Post-processing must always use this instead of
[`load_config`](@ref), otherwise editing `config.toml` silently re-parametrizes
the analysis of old runs (disruption windows, session times, physics rates).
"""
function load_run_config(run_dir::String)
    snapshot = joinpath(run_dir, "config_snapshot.toml")
    if isfile(snapshot)
        try
            return TOML.parsefile(snapshot)
        catch e
            @warn "[CONFIG] Corrupt config_snapshot.toml in $run_dir — falling back to the project config.toml." exception =
                e
        end
    end
    return load_config()
end

# --- Checked config coercions ---
"""
    checked_number(v, name::String) -> Float64

Coerces a config value to `Float64`, aborting with a clean `[CONFIG]` error
when the TOML value is not numeric (e.g. a quoted `"3600"`), instead of
surfacing a raw `MethodError` from deep inside the validator or a builder.
"""
function checked_number(v, name::String)
    (v isa Real && !(v isa Bool)) ||
        config_error("[CONFIG] $name must be a number (got $(repr(v))).")
    return Float64(v)
end

"""
    checked_integer(v, name::String) -> Int

Coerces a config value to `Int` with a clean `[CONFIG]` error on non-integer
TOML values (strings, floats, booleans).
"""
function checked_integer(v, name::String)
    (v isa Integer && !(v isa Bool)) ||
        config_error("[CONFIG] $name must be an integer (got $(repr(v))).")
    return Int(v)
end

"""
    checked_string(v, name::String) -> String

Coerces a config value to `String` with a clean `[CONFIG]` error when the
TOML value is not a string.
"""
function checked_string(v, name::String)
    v isa AbstractString ||
        config_error("[CONFIG] $name must be a string (got $(repr(v))).")
    return String(v)
end

"""
    checked_flag(v, name::String) -> Bool

Coerces a config value to `Bool` with a clean `[CONFIG]` rejection when the
TOML value is not a boolean (e.g. a quoted `"true"`).
"""
function checked_flag(v, name::String)
    v isa Bool || config_error("[CONFIG] $name must be a boolean (got $(repr(v))).")
    return v
end

"""
    config_error(msg::AbstractString)

Rejects a configuration with an `ArgumentError` carrying the `[CONFIG]`
message — the single throw point for every validator and coercion rejection,
so callers can rely on the exception type.
"""
config_error(msg::AbstractString) = throw(ArgumentError(msg))

"""
    required_value(section::AbstractDict, sec_name::String, key::String)

Fetches a required configuration key, rejecting with a precise `[CONFIG]`
message (instead of a raw `KeyError`) when it is absent.
"""
required_value(section::AbstractDict, sec_name::String, key::String) =
    haskey(section, key) ? section[key] :
    config_error("[CONFIG] Missing required key $sec_name.$key.")

"""
    normalize_target_rows(raw) -> Union{Symbol, Vector{Int}}

Parses the `post_processing.target_event_rows` configuration entry into a
canonical form. Accepts the bare string `"all"`, or an array mixing integer row
indices (`-1` meaning the final row), `"start:stop"` range strings, and the
string `"all"`. Returns the symbol `:all` when every row is requested,
otherwise a sorted vector of unique row indices. Unrecognized entries are
skipped with a warning.

# Examples
```jldoctest
julia> TelemetryCore.normalize_target_rows("all")
:all

julia> TelemetryCore.normalize_target_rows([3, "1:2", 3, -1])
4-element Vector{Int64}:
 -1
  1
  2
  3
```
"""
function normalize_target_rows(raw)
    raw == "all" && return :all
    rows = Int[]
    if raw isa AbstractArray
        for item in raw
            if item == "all"
                return :all
            elseif item isa Integer
                push!(rows, Int(item))
            elseif item isa AbstractString && occursin(":", item)
                parts = split(item, ":")
                start_idx = length(parts) == 2 ? tryparse(Int, parts[1]) : nothing
                end_idx = length(parts) == 2 ? tryparse(Int, parts[2]) : nothing
                if start_idx !== nothing && end_idx !== nothing && start_idx <= end_idx
                    append!(rows, start_idx:end_idx)
                else
                    @warn "[CONFIG] Ignoring malformed target_event_rows range: $item"
                end
            else
                @warn "[CONFIG] Ignoring unrecognized target_event_rows entry: $item"
            end
        end
    else
        @warn "[CONFIG] Unrecognized target_event_rows value: $raw (expected \"all\" or an array)"
    end
    return sort!(unique!(rows))
end

# --- Configuration Validation ---

# Schema of recognized sections and keys. Anything outside it draws a
# warning in validate_config: a typo'd key silently falling back to a
# default is the quietest failure mode a config can carry.
"""
    STORAGE_CALIBRATION_DEFAULTS

Measured calibration constants of the artifact estimator, overridable
key-by-key in `[storage]`. The `bytes_*` disk constants are per-artifact CSV
or figure sizes; `bytes_replay_cell` is the post-processing replay RAM per
(metrics row × batch) membership. The schema entry for `[storage]` and the
validator both iterate this table, so a new calibration key is declared
exactly once.
"""
const STORAGE_CALIBRATION_DEFAULTS = (
    bytes_per_sample = 15.0,      # one Float32 CSV value + newline
    bytes_batch_metadata = 96.0,  # metadata.json
    bytes_event_row = 64.0,       # events_tx/rx.csv row
    bytes_metrics_row = 160.0,    # mission_profile.csv row
    bytes_mask_cell = 4.0,        # mask-timeline cell (digit + separator)
    bytes_pointwise_cell = 10.0,  # point-wise expansion row
    bytes_plot = 2.0e6,           # one PNG at px_per_unit = 4
    bytes_plot_pdf = 100_000.0,   # vector PDF twin of one figure
    bytes_replay_cell = 12.0,     # replay RAM per (row x batch) membership
    bytes_log_per_batch = 600.0,  # emitter+receiver log lines per batch
)

const KNOWN_CONFIG_KEYS = Dict(
    "simulation" => [
        "speed_up",
        "start_sim_time",
        "mission_wall_seconds",
        "test_duration_sec", # deprecated alias of mission_wall_seconds
        "initial_downtime_days",
        "rng_seed",
        "max_storage_gb",
    ],
    "storage" => vcat(
        ["max_storage_gb", "max_file_count", "max_ram_gb", "onboard_capacity_days"],
        String.(collect(keys(STORAGE_CALIBRATION_DEFAULTS))),
    ),
    "retention" => ["enabled", "grace_hours", "high_watermark_gb", "log_rotate_mb"],
    "telemetry" => [
        "session_start",
        "session_duration_hours",
        "max_batches_per_hour",
        "downlink_kbps",
        "onboard_data_rate_kbps",
        "bandwidth_profile",
        "max_inflight_batches",
        "min_link_factor",
        "sigmoid_steepness",
        "gaussian_sigma",
        "range_million_km",
    ],
    "physics" => [
        "data_source",
        "external_data_path",
        "sample_rate",
        "segment_duration_sec",
        "batch_size",
        "confusion_observation_years",
        "noise_f_min_hz",
        "signal_injection_probability",
    ],
    "packet_loss" => [
        "enabled",
        "model",
        "p_loss",
        "p_good_to_bad",
        "p_bad_to_good",
        "p_loss_good",
        "p_loss_bad",
        "on_loss",
        "max_retries",
    ],
    "disruption" => ["events"],
    "disaster" => ["events"],
    "dashboard" => ["open_live_viewer", "open_receiver_log", "open_emitter_log"],
    "post_processing" => [
        "generate_mask_timeline",
        "generate_batch_matrix", # deprecated alias of generate_mask_timeline
        "expand_to_pointwise_masks",
        "target_event_rows",
        "alert_latency",
        "alert_lookback_hours",
        "delivery_delay",
        "delivery_requirement_hours",
        "hdf5_export",
        "publication",
    ],
    "events" => ["markers"],
    "ground" => ["processing_latency_hours"],
    "contacts" => [
        "seasonal_extension_hours",
        "season_period_days",
        "season_peak_day_of_year",
        "schedule_csv",
        "passes",
        "exceptions",
        "low_latency_enabled",
        "low_latency_capacity_fraction",
        "low_latency_periods",
    ],
    "provenance" => String[], # pipeline-generated; free-form by design
    "supervision" => ["on_component_failure", "max_restarts", "watchdog_sec"],
)
const KNOWN_EVENT_KEYS = [
    "type",
    "label",
    "start_day",
    "duration_hours",
    "severity",
    "recovery_hours",
    "loss_multiplier",
    "affects",
]
const KNOWN_PUBLICATION_KEYS = ["enabled", "format", "column_width_mm", "export_dir"]
const KNOWN_MARKER_KEYS = [
    "time",
    "label",
    "low_latency_after_hours",
    "low_latency_duration_hours",
    "low_latency_capacity_fraction",
]
const KNOWN_CONTACT_ENTRY_KEYS = Dict(
    "passes" => ["start", "duration_hours"],
    "exceptions" => ["date", "start", "duration_hours"],
    "low_latency_periods" => ["start", "duration_hours", "capacity_fraction", "label"],
)

# --- Configuration accessors ---
"""
    aliased_value(section, sec_name, key, legacy_key, default)

Reads `key` from `section`, falling back to the deprecated `legacy_key` with
a one-time warning, or to `default` when neither is present. Deprecated
keys are accepted until 1.0.0.
"""
function aliased_value(
    section::AbstractDict,
    sec_name::String,
    key::String,
    legacy_key::String,
    default,
)
    haskey(section, key) && return section[key]
    if haskey(section, legacy_key)
        @warn "[CONFIG] $sec_name.$legacy_key is deprecated — rename it to $sec_name.$key (the alias is removed at 1.0.0)." maxlog =
            1
        return section[legacy_key]
    end
    return default
end

"""
    mission_wall_seconds(cfg::AbstractDict) -> Float64

Validated wall-clock mission span `simulation.mission_wall_seconds` (> 0);
the deprecated `simulation.test_duration_sec` is accepted with a warning.

# Examples
```jldoctest
julia> TelemetryCore.mission_wall_seconds(Dict{String,Any}("simulation" => Dict{String,Any}("mission_wall_seconds" => 168.0)))
168.0
```
"""
function mission_wall_seconds(cfg::AbstractDict)
    sim = get(cfg, "simulation", Dict{String,Any}())
    raw = aliased_value(
        sim,
        "simulation",
        "mission_wall_seconds",
        "test_duration_sec",
        nothing,
    )
    raw === nothing &&
        config_error("[CONFIG] Missing required key simulation.mission_wall_seconds.")
    v = checked_number(raw, "simulation.mission_wall_seconds")
    v > 0.0 ||
        config_error("[CONFIG] simulation.mission_wall_seconds must be > 0 (got $v).")
    return v
end

"""
    normalize_profile!(df::DataFrame) -> DataFrame

Brings a `mission_profile.csv` frame to the current column schema: the
pre-0.10 `Ground_Archive` column (the live + archive total) is renamed
`Ground_Total`. Every reader of the profile passes through here.
"""
function normalize_profile!(df::DataFrame)
    if !hasproperty(df, :Ground_Total) && hasproperty(df, :Ground_Archive)
        DataFrames.rename!(df, :Ground_Archive => :Ground_Total)
    end
    return df
end

# Validated, typed views of the configuration sections consumed by more than
# one component. The validator, the channel builders, the storage estimator,
# the post-processing tools, and the entry-point script all read through
# these, so every bound is enforced in exactly one place and every consumer
# sees the same defaults.

"""
    telemetry_settings(cfg::AbstractDict) -> NamedTuple

Validated `[telemetry]` parameters: `session_start::Time`,
`session_duration::Second`, `bandwidth_profile::String`,
`sigmoid_steepness`, `gaussian_sigma`, `max_batches_per_hour`,
`max_inflight_batches::Int`, `min_link_factor`, `range_million_km ≥ 0`
(spacecraft–Earth range; `0` disables the light-time delay), and the
derived `round_trip_light_time_sec = 2 · range / c`. The link capacity is
given either as `max_batches_per_hour` or as the physical pair
`downlink_kbps` and `onboard_data_rate_kbps` (both > 0), from which the
capacity in batches per hour follows through the batch content span
(`[physics]`); the two forms are mutually exclusive. The result carries
`nominal_batch_transfer_sec` (the transfer time of one batch at full
capacity), `catch_up_ratio` (downlink over production rate; `NaN` in the
batches-per-hour form), and `onboard_data_rate_kbps` (`NaN` likewise). Bounds are enforced with
`[CONFIG]` errors; absent keys take the documented defaults (post-processing
of legacy snapshots), while the live-config required-key policy is applied
by [`validate_config`](@ref).

# Examples
```jldoctest
julia> cfg = Dict{String,Any}(
           "telemetry" => Dict{String,Any}("downlink_kbps" => 230.0, "onboard_data_rate_kbps" => 75.0),
           "physics" => Dict{String,Any}(
               "data_source" => "synthetic",
               "sample_rate" => 4.0,
               "segment_duration_sec" => 60.0,
               "batch_size" => 10,
           ),
       );

julia> tel = TelemetryCore.telemetry_settings(cfg);

julia> round(tel.nominal_batch_transfer_sec; digits = 1), round(tel.max_batches_per_hour; digits = 1), round(tel.catch_up_ratio; digits = 2)
(195.7, 18.4, 3.07)

julia> tel = TelemetryCore.telemetry_settings(Dict{String,Any}("telemetry" => Dict{String,Any}("max_batches_per_hour" => 20.0)));

julia> tel.nominal_batch_transfer_sec, isnan(tel.catch_up_ratio)
(180.0, true)
```
"""
function telemetry_settings(cfg::AbstractDict)
    tel = get(cfg, "telemetry", Dict{String,Any}())
    start_raw = get(tel, "session_start", "08:00:00")
    session_start = try
        Time(start_raw)
    catch
        config_error("[CONFIG] telemetry.session_start is not a parseable time: $start_raw")
    end
    session_hours = checked_number(
        get(tel, "session_duration_hours", 8.0),
        "telemetry.session_duration_hours",
    )
    0.0 < session_hours <= 24.0 || config_error(
        "[CONFIG] telemetry.session_duration_hours must lie in (0, 24] (got $session_hours): the daily scheduler wraps Time arithmetic at 24 h.",
    )
    rate_form = haskey(tel, "downlink_kbps") || haskey(tel, "onboard_data_rate_kbps")
    if rate_form
        haskey(tel, "max_batches_per_hour") && config_error(
            "[CONFIG] telemetry.max_batches_per_hour and the rate pair downlink_kbps / onboard_data_rate_kbps are mutually exclusive.",
        )
        downlink_kbps =
            checked_number(get(tel, "downlink_kbps", 0.0), "telemetry.downlink_kbps")
        downlink_kbps > 0.0 || config_error(
            "[CONFIG] telemetry.downlink_kbps must be > 0 (got $downlink_kbps).",
        )
        onboard_kbps = checked_number(
            get(tel, "onboard_data_rate_kbps", 0.0),
            "telemetry.onboard_data_rate_kbps",
        )
        onboard_kbps > 0.0 || config_error(
            "[CONFIG] telemetry.onboard_data_rate_kbps must be > 0 (got $onboard_kbps).",
        )
        physics = physics_settings(cfg)
        batch_span_sec = physics.batch_size * physics.segment_duration_sec
        nominal_batch_transfer_sec = batch_span_sec * onboard_kbps / downlink_kbps
        max_batches_per_hour = 3600.0 / nominal_batch_transfer_sec
        catch_up_ratio = downlink_kbps / onboard_kbps
        onboard_data_rate_kbps = onboard_kbps
    else
        max_batches_per_hour = checked_number(
            get(tel, "max_batches_per_hour", 20.0),
            "telemetry.max_batches_per_hour",
        )
        max_batches_per_hour > 0.0 || config_error(
            "[CONFIG] telemetry.max_batches_per_hour must be > 0 (got $max_batches_per_hour).",
        )
        nominal_batch_transfer_sec = 3600.0 / max_batches_per_hour
        catch_up_ratio = NaN
        onboard_data_rate_kbps = NaN
    end
    bandwidth_profile =
        checked_string(get(tel, "bandwidth_profile", "sine"), "telemetry.bandwidth_profile")
    max_inflight = checked_integer(
        get(tel, "max_inflight_batches", 5),
        "telemetry.max_inflight_batches",
    )
    max_inflight >= 1 || config_error(
        "[CONFIG] telemetry.max_inflight_batches must be ≥ 1 (got $max_inflight).",
    )
    min_link_factor =
        checked_number(get(tel, "min_link_factor", 0.05), "telemetry.min_link_factor")
    0.0 <= min_link_factor < 1.0 || config_error(
        "[CONFIG] telemetry.min_link_factor = $min_link_factor outside [0, 1).",
    )
    sigmoid_steepness =
        checked_number(get(tel, "sigmoid_steepness", 10.0), "telemetry.sigmoid_steepness")
    sigmoid_steepness > 0.0 || config_error(
        "[CONFIG] telemetry.sigmoid_steepness must be > 0 (got $sigmoid_steepness).",
    )
    gaussian_sigma =
        checked_number(get(tel, "gaussian_sigma", 0.15), "telemetry.gaussian_sigma")
    gaussian_sigma > 0.0 ||
        config_error("[CONFIG] telemetry.gaussian_sigma must be > 0 (got $gaussian_sigma).")
    range_million_km =
        checked_number(get(tel, "range_million_km", 0.0), "telemetry.range_million_km")
    range_million_km >= 0.0 || config_error(
        "[CONFIG] telemetry.range_million_km must be ≥ 0 (got $range_million_km).",
    )
    return (
        session_start = session_start,
        session_duration = Second(round(Int, session_hours * 3600)),
        bandwidth_profile = bandwidth_profile,
        sigmoid_steepness = sigmoid_steepness,
        gaussian_sigma = gaussian_sigma,
        max_batches_per_hour = max_batches_per_hour,
        nominal_batch_transfer_sec = nominal_batch_transfer_sec,
        catch_up_ratio = catch_up_ratio,
        onboard_data_rate_kbps = onboard_data_rate_kbps,
        max_inflight_batches = max_inflight,
        min_link_factor = min_link_factor,
        range_million_km = range_million_km,
        round_trip_light_time_sec = 2 * range_million_km * 1e9 / C_LIGHT,
    )
end

"""
    visibility_model(cfg::AbstractDict) -> VisibilityModel

The [`VisibilityModel`](@ref) described by `[telemetry]` and `[contacts]`,
built from [`telemetry_settings`](@ref) and [`contacts_settings`](@ref).
Low-latency periods enter only when `contacts.low_latency_enabled` is set.
"""
function visibility_model(cfg::AbstractDict)
    s = telemetry_settings(cfg)
    c = contacts_settings(cfg)
    return VisibilityModel(
        s.session_start,
        s.session_duration,
        s.bandwidth_profile,
        s.sigmoid_steepness,
        s.gaussian_sigma,
        Second(round(Int, 3600 * c.seasonal_extension_hours)),
        c.season_period_days,
        c.season_peak_day_of_year,
        c.exceptions,
        c.passes,
        c.low_latency_enabled ? c.low_latency_periods : ContactWindow[],
    )
end

"""
    capacity_balance(cfg::AbstractDict) -> NamedTuple

Capacity of one nominal pass against the daily production, from
[`telemetry_settings`](@ref), [`physics_settings`](@ref), and the pass
profile: `rate_form` (the capacity is given as the physical rate pair),
`profile_mean` ([`profile_mean`](@ref) of the pass profile), `pass_hours`
(`telemetry.session_duration_hours`), `capacity_per_pass` (batches,
`max_batches_per_hour × profile_mean × pass_hours`), and `produced_per_day`
(batches, `86 400 / (batch_size × segment_duration_sec)`). Seasonal
extensions, exceptions, and low-latency periods are not included: the
figure is the balance of the nominal daily pass.
"""
function capacity_balance(cfg::AbstractDict)
    tel = telemetry_settings(cfg)
    physics = physics_settings(cfg)
    mean = profile_mean(visibility_model(cfg))
    pass_hours = tel.session_duration.value / 3600
    return (
        rate_form = !isnan(tel.catch_up_ratio),
        profile_mean = mean,
        pass_hours = pass_hours,
        capacity_per_pass = tel.max_batches_per_hour * mean * pass_hours,
        produced_per_day = 86_400 / (physics.batch_size * physics.segment_duration_sec),
    )
end

"""
    loss_channel_settings(cfg::AbstractDict) -> NamedTuple

Validated `[packet_loss]` parameters: `enabled`, `model` (`"bernoulli"` or
`"gilbert_elliott"`, lower-cased), the five probabilities `p_loss`,
`p_good_to_bad`, `p_bad_to_good`, `p_loss_good`, `p_loss_bad` (each in
`[0, 1]`), `on_loss` (`"retransmit"` or `"drop"`), and `max_retries ≥ 0`.
Types, enumerations, and bounds are enforced regardless of `enabled`: a
malformed-but-disabled section fails fast instead of lying dormant.
"""
function loss_channel_settings(cfg::AbstractDict)
    pl = get(cfg, "packet_loss", Dict{String,Any}())
    enabled = checked_flag(get(pl, "enabled", false), "packet_loss.enabled")
    model = lowercase(checked_string(get(pl, "model", "bernoulli"), "packet_loss.model"))
    model in ("bernoulli", "gilbert_elliott") || config_error(
        "[CONFIG] Unknown packet_loss.model = \"$model\" (expected \"bernoulli\" or \"gilbert_elliott\").",
    )
    probability =
        (key, default) -> begin
            v = checked_number(get(pl, key, default), "packet_loss.$key")
            0.0 <= v <= 1.0 ||
                config_error("[CONFIG] packet_loss.$key = $v outside [0, 1].")
            v
        end
    on_loss =
        lowercase(checked_string(get(pl, "on_loss", "retransmit"), "packet_loss.on_loss"))
    on_loss in ("retransmit", "drop") || config_error(
        "[CONFIG] Unknown packet_loss.on_loss = \"$on_loss\" (expected \"retransmit\" or \"drop\").",
    )
    max_retries = checked_integer(get(pl, "max_retries", 3), "packet_loss.max_retries")
    max_retries >= 0 ||
        config_error("[CONFIG] packet_loss.max_retries must be ≥ 0 (got $max_retries).")
    return (
        enabled = enabled,
        model = model,
        p_loss = probability("p_loss", 0.05),
        p_good_to_bad = probability("p_good_to_bad", 0.0),
        p_bad_to_good = probability("p_bad_to_good", 1.0),
        p_loss_good = probability("p_loss_good", 0.0),
        p_loss_bad = probability("p_loss_bad", 0.0),
        on_loss = on_loss,
        max_retries = max_retries,
    )
end

"""
    physics_settings(cfg::AbstractDict) -> NamedTuple

Validated `[physics]` parameters: `data_source` (`"synthetic"` or
`"external"`), `external_data_path` (as configured; consumers resolve it
against the package root), `sample_rate > 0`, `segment_duration_sec > 0`,
and `batch_size ≥ 1`, with at least two samples per segment (the FFT
synthesis block). The four core keys are required. The optional
`confusion_observation_years` (one of 0.5, 1.0, 2.0, 4.0; default 1.0)
selects the galactic-confusion fit of the noise model and
`noise_f_min_hz > 0` (default 1e-5) the lower edge of the synthesized band.
The retired `signal_injection_probability` is accepted with a deprecation
warning and ignored (event instants are `[[events.markers]]`). The
existence of the external file is checked by [`validate_config`](@ref)
only, so post-processing of a finished run does not depend on the input
file still being present.
"""
function physics_settings(cfg::AbstractDict)
    phy = get(cfg, "physics", Dict{String,Any}())
    sample_rate =
        checked_number(required_value(phy, "physics", "sample_rate"), "physics.sample_rate")
    sample_rate > 0.0 ||
        config_error("[CONFIG] physics.sample_rate must be > 0 (got $sample_rate).")
    segment_duration = checked_number(
        required_value(phy, "physics", "segment_duration_sec"),
        "physics.segment_duration_sec",
    )
    segment_duration > 0.0 || config_error(
        "[CONFIG] physics.segment_duration_sec must be > 0 (got $segment_duration).",
    )
    batch_size =
        checked_integer(required_value(phy, "physics", "batch_size"), "physics.batch_size")
    batch_size >= 1 ||
        config_error("[CONFIG] physics.batch_size must be ≥ 1 (got $batch_size).")
    n_samples = sample_rate * segment_duration
    n_samples >= 2.0 || config_error(
        "[CONFIG] sample_rate × segment_duration_sec = $n_samples < 2: FFT synthesis needs ≥ 2 samples per segment.",
    )
    data_source =
        checked_string(required_value(phy, "physics", "data_source"), "physics.data_source")
    data_source in ("synthetic", "external") || config_error(
        "[CONFIG] Unknown physics.data_source = \"$data_source\" (expected \"synthetic\" or \"external\").",
    )
    external_data_path =
        checked_string(get(phy, "external_data_path", ""), "physics.external_data_path")
    confusion_years = checked_number(
        get(phy, "confusion_observation_years", 1.0),
        "physics.confusion_observation_years",
    )
    confusion_years in (0.5, 1.0, 2.0, 4.0) || config_error(
        "[CONFIG] physics.confusion_observation_years must be one of 0.5, 1.0, 2.0, 4.0 (got $confusion_years).",
    )
    noise_f_min = checked_number(get(phy, "noise_f_min_hz", 1e-5), "physics.noise_f_min_hz")
    noise_f_min > 0.0 ||
        config_error("[CONFIG] physics.noise_f_min_hz must be > 0 (got $noise_f_min).")
    haskey(phy, "signal_injection_probability") &&
        @warn "[CONFIG] physics.signal_injection_probability is deprecated and ignored — declare event instants as [[events.markers]] (the key is removed at 1.0.0)." maxlog =
            1
    return (
        data_source = data_source,
        external_data_path = external_data_path,
        sample_rate = sample_rate,
        segment_duration_sec = segment_duration,
        batch_size = batch_size,
        confusion_observation_years = confusion_years,
        noise_f_min_hz = noise_f_min,
    )
end

"""
    EventMarker

One `[[events.markers]]` entry: the mission instant `time` of an event of
interest (a transient, a glitch), its `label`, and an optional triggered
low-latency period — `low_latency_after_hours` after the marker, lasting
`low_latency_duration_hours` (`0` = none) at `low_latency_capacity_fraction`
of peak capacity (`NaN` = the `[contacts]` default).
"""
struct EventMarker
    time::DateTime
    label::String
    low_latency_after_hours::Float64
    low_latency_duration_hours::Float64
    low_latency_capacity_fraction::Float64
end

EventMarker(time::DateTime, label::String) = EventMarker(time, label, 0.0, 0.0, NaN)

"""
    event_marker_settings(cfg::AbstractDict) -> Vector{EventMarker}

Validated `[[events.markers]]` entries sorted by time: `time` (datetime,
required), `label` (default `marker <i>`), `low_latency_after_hours ≥ 0`,
`low_latency_duration_hours ≥ 0`, and `low_latency_capacity_fraction ∈
(0, 1]` when given. Labels must be unique. A malformed marker raises a
`[CONFIG]` error.
"""
function event_marker_settings(cfg::AbstractDict)
    markers = EventMarker[]
    for (i, e) in enumerate(get(get(cfg, "events", Dict{String,Any}()), "markers", Any[]))
        e isa AbstractDict ||
            config_error("[CONFIG] events.markers[$i] must be a table of marker keys.")
        time = parsed_datetime(get(e, "time", nothing), "events.markers[$i].time")
        label = checked_string(get(e, "label", "marker $i"), "events.markers[$i].label")
        after = checked_number(
            get(e, "low_latency_after_hours", 0.0),
            "events.markers[$i].low_latency_after_hours",
        )
        after >= 0.0 || config_error(
            "[CONFIG] events.markers[$i].low_latency_after_hours must be ≥ 0 (got $after).",
        )
        duration = checked_number(
            get(e, "low_latency_duration_hours", 0.0),
            "events.markers[$i].low_latency_duration_hours",
        )
        duration >= 0.0 || config_error(
            "[CONFIG] events.markers[$i].low_latency_duration_hours must be ≥ 0 (got $duration).",
        )
        fraction = NaN
        if haskey(e, "low_latency_capacity_fraction")
            fraction = checked_number(
                e["low_latency_capacity_fraction"],
                "events.markers[$i].low_latency_capacity_fraction",
            )
            0.0 < fraction <= 1.0 || config_error(
                "[CONFIG] events.markers[$i].low_latency_capacity_fraction must lie in (0, 1] (got $fraction).",
            )
        end
        push!(markers, EventMarker(time, label, after, duration, fraction))
    end
    labels = [m.label for m in markers]
    allunique(labels) ||
        config_error("[CONFIG] events.markers labels must be unique (got $labels).")
    return sort!(markers; by = m -> m.time)
end

"""
    ground_settings(cfg::AbstractDict) -> NamedTuple

Validated `[ground]` section: `processing_latency_hours ≥ 0` (default 1,
the low-latency alert pipeline budget added to every alert latency).
"""
function ground_settings(cfg::AbstractDict)
    g = get(cfg, "ground", Dict{String,Any}())
    processing = checked_number(
        get(g, "processing_latency_hours", 1.0),
        "ground.processing_latency_hours",
    )
    processing >= 0.0 || config_error(
        "[CONFIG] ground.processing_latency_hours must be ≥ 0 (got $processing).",
    )
    return (processing_latency_hours = processing,)
end

"""
    publication_settings(cfg::AbstractDict) -> NamedTuple

Validated `[post_processing.publication]`: `enabled` (default `false`),
`format` (`"pdf"` | `"svg"`, default `"pdf"`), `column_width_mm ∈ [40, 400]`
(default 178, the double-column width the figures are designed at; 86–90
for a single column), and `export_dir` (default `""` =
`<run_dir>/publication`; relative paths resolve against the current
directory). Unrecognized keys warn.
"""
function publication_settings(cfg::AbstractDict)
    pub = get(
        get(cfg, "post_processing", Dict{String,Any}()),
        "publication",
        Dict{String,Any}(),
    )
    pub isa AbstractDict ||
        config_error("[CONFIG] post_processing.publication must be a table of keys.")
    for key in keys(pub)
        key in KNOWN_PUBLICATION_KEYS ||
            @warn "[CONFIG] Unrecognized key post_processing.publication.$key — ignored (typo?)."
    end
    enabled =
        checked_flag(get(pub, "enabled", false), "post_processing.publication.enabled")
    format = checked_string(get(pub, "format", "pdf"), "post_processing.publication.format")
    format in ("pdf", "svg") || config_error(
        "[CONFIG] post_processing.publication.format must be \"pdf\" or \"svg\" (got \"$format\").",
    )
    width = checked_number(
        get(pub, "column_width_mm", 178.0),
        "post_processing.publication.column_width_mm",
    )
    40.0 <= width <= 400.0 || config_error(
        "[CONFIG] post_processing.publication.column_width_mm must lie in [40, 400] (got $width).",
    )
    export_dir =
        checked_string(get(pub, "export_dir", ""), "post_processing.publication.export_dir")
    return (
        enabled = enabled,
        format = format,
        column_width_mm = width,
        export_dir = export_dir,
    )
end

"""
    batch_markers(markers::Vector{EventMarker}, epoch::DateTime, stop::DateTime) -> Vector{EventMarker}

The markers whose instant lies in the content span `[epoch, stop)` of a
batch.
"""
function batch_markers(markers::Vector{EventMarker}, epoch::DateTime, stop::DateTime)
    return filter(m -> epoch <= m.time < stop, markers)
end

"""
    save_markers(run_dir::String, markers::Vector{EventMarker})

Writes `<run_dir>/markers.csv` (`SimTime, Label`) — the run's event
instants for consumers and post-processing; nothing is written when there
are no markers.
"""
function save_markers(run_dir::String, markers::Vector{EventMarker})
    isempty(markers) && return nothing
    df = DataFrame(SimTime = [m.time for m in markers], Label = [m.label for m in markers])
    safe_csv_write(joinpath(run_dir, "markers.csv"), df)
    return nothing
end

"""
    load_markers(run_dir::String) -> Vector{EventMarker}

The markers recorded in `<run_dir>/markers.csv` (empty when absent), as
plain [`EventMarker`](@ref)s without triggered periods.
"""
function load_markers(run_dir::String)
    path = joinpath(run_dir, "markers.csv")
    isfile(path) || return EventMarker[]
    df = CSV.read(path, DataFrame)
    return [EventMarker(DateTime(r.SimTime), String(r.Label)) for r in eachrow(df)]
end

"""
    supervision_settings(cfg::AbstractDict) -> NamedTuple

Validated `[supervision]` parameters: `on_component_failure` (`"abort"`,
`"continue"`, or `"restart"`, lower-cased; default `"abort"`),
`max_restarts ≥ 0` (default 3), `watchdog_sec > 0` (default 30).
"""
function supervision_settings(cfg::AbstractDict)
    sup = get(cfg, "supervision", Dict{String,Any}())
    policy = lowercase(
        checked_string(
            get(sup, "on_component_failure", "abort"),
            "supervision.on_component_failure",
        ),
    )
    policy in ("abort", "continue", "restart") || config_error(
        "[CONFIG] Unknown supervision.on_component_failure = \"$policy\" (expected \"abort\", \"continue\", or \"restart\").",
    )
    max_restarts = checked_integer(get(sup, "max_restarts", 3), "supervision.max_restarts")
    max_restarts >= 0 ||
        config_error("[CONFIG] supervision.max_restarts must be ≥ 0 (got $max_restarts).")
    watchdog_sec =
        checked_number(get(sup, "watchdog_sec", 30.0), "supervision.watchdog_sec")
    watchdog_sec > 0.0 ||
        config_error("[CONFIG] supervision.watchdog_sec must be > 0 (got $watchdog_sec).")
    return (
        on_component_failure = policy,
        max_restarts = max_restarts,
        watchdog_sec = watchdog_sec,
    )
end

"""
    DisruptionEventSettings

One validated `[[disruption.events]]` entry as returned by
[`disruption_event_settings`](@ref).
"""
const DisruptionEventSettings = NamedTuple{
    (
        :type,
        :label,
        :start_day,
        :duration_hours,
        :recovery_hours,
        :severity,
        :loss_multiplier,
        :affects,
    ),
    Tuple{String,String,Float64,Float64,Float64,Float64,Float64,String},
}

"""
    disruption_event_settings(cfg::AbstractDict) -> Vector{DisruptionEventSettings}

Validated `[[disruption.events]]` entries in file order (the legacy
`[[disaster.events]]` section name is accepted): `type`, `label`,
`start_day ≥ 0`, `duration_hours > 0`, `recovery_hours ≥ 0`,
`severity ∈ [0, 1]`, `loss_multiplier`, and `affects` — `"link"` (the
default: a capacity and loss disruption) or `"generation"` (a scheduled
gap in data production of `duration_hours`; severity, recovery, and loss
keys are ignored). `type = "antenna_repointing"` defaults to
`"generation"`. A malformed event raises an error rather than being
skipped: a silently missing disruption invalidates the scenario.
"""
function disruption_event_settings(cfg::AbstractDict)
    d = get(cfg, "disruption", get(cfg, "disaster", Dict{String,Any}()))
    events = DisruptionEventSettings[]
    for (i, e) in enumerate(get(d, "events", Any[]))
        e isa AbstractDict ||
            config_error("[CONFIG] disruption.events[$i] must be a table of event keys.")
        start_day =
            checked_number(get(e, "start_day", -1.0), "disruption.events[$i].start_day")
        start_day >= 0.0 || config_error(
            "[CONFIG] disruption.events[$i].start_day must be ≥ 0 (got $start_day).",
        )
        duration_hours = checked_number(
            get(e, "duration_hours", 24.0),
            "disruption.events[$i].duration_hours",
        )
        duration_hours > 0.0 || config_error(
            "[CONFIG] disruption.events[$i].duration_hours must be > 0 (got $duration_hours).",
        )
        recovery_hours = checked_number(
            get(e, "recovery_hours", 0.0),
            "disruption.events[$i].recovery_hours",
        )
        recovery_hours >= 0.0 || config_error(
            "[CONFIG] disruption.events[$i].recovery_hours must be ≥ 0 (got $recovery_hours).",
        )
        severity = checked_number(get(e, "severity", 1.0), "disruption.events[$i].severity")
        0.0 <= severity <= 1.0 || config_error(
            "[CONFIG] disruption.events[$i].severity = $severity outside [0, 1].",
        )
        loss_multiplier = checked_number(
            get(e, "loss_multiplier", 1.0),
            "disruption.events[$i].loss_multiplier",
        )
        type =
            checked_string(get(e, "type", "link_disruption"), "disruption.events[$i].type")
        affects = checked_string(
            get(e, "affects", type == "antenna_repointing" ? "generation" : "link"),
            "disruption.events[$i].affects",
        )
        affects in ("link", "generation") || config_error(
            "[CONFIG] disruption.events[$i].affects must be \"link\" or \"generation\" (got \"$affects\").",
        )
        push!(
            events,
            (
                type = type,
                label = checked_string(get(e, "label", ""), "disruption.events[$i].label"),
                start_day = start_day,
                duration_hours = duration_hours,
                recovery_hours = recovery_hours,
                severity = severity,
                loss_multiplier = loss_multiplier,
                affects = affects,
            ),
        )
    end
    return events
end

"""
    onboard_capacity(cfg::AbstractDict) -> NamedTuple

The on-board recorder ceiling from `storage.onboard_capacity_days > 0`
(default 14, the Definition Study Report's autonomy without ground
contact): `days`, `batches` (the ceiling the emitter enforces — production
over that span in whole batches, at least one), and `gigabit` (the
physical volume when the link is given as a rate pair, else `NaN`).
"""
function onboard_capacity(cfg::AbstractDict)
    st = get(cfg, "storage", Dict{String,Any}())
    days = checked_number(
        get(st, "onboard_capacity_days", 14.0),
        "storage.onboard_capacity_days",
    )
    days > 0.0 ||
        config_error("[CONFIG] storage.onboard_capacity_days must be > 0 (got $days).")
    physics = physics_settings(cfg)
    span_sec = physics.batch_size * physics.segment_duration_sec
    tel = telemetry_settings(cfg)
    return (
        days = days,
        batches = max(1, floor(Int, days * 86_400 / span_sec)),
        gigabit = days * 86_400 * tel.onboard_data_rate_kbps / 1e6,
    )
end

"""
    open_recorder_gap(run_dir::String) -> Bool

Whether the last recorder-overflow gap in `events_tx.csv` (rows with
Batch = `RECORDER`) is still open — a `gap_start` without its `gap_end` —
so a re-attaching emitter closes it when the buffer has room again.
"""
function open_recorder_gap(run_dir::String)
    path = joinpath(run_dir, "events_tx.csv")
    isfile(path) || return false
    df = CSV.read(path, DataFrame)
    isempty(df) && return false
    rows = df[df.Batch .== "RECORDER", :]
    return count(==("gap_start"), rows.Event) > count(==("gap_end"), rows.Event)
end

"""
    ContactWindow

One ground-contact interval on the mission timeline: `start` and `stop`
(`DateTime`, closed interval), the link `capacity` relative to peak (`1.0`
for a nominal pass; the station-availability fraction of a low-latency
period), the `low_latency` flag, and a free-text `label` (empty for
nominal passes). `ContactWindow(start, stop)` builds a nominal pass.
"""
struct ContactWindow
    start::DateTime
    stop::DateTime
    capacity::Float64
    low_latency::Bool
    label::String
end

ContactWindow(start::DateTime, stop::DateTime) = ContactWindow(start, stop, 1.0, false, "")

"""
    ContactsSettings

Validated `[contacts]` section as returned by [`contacts_settings`](@ref).
"""
const ContactsSettings = NamedTuple{
    (
        :seasonal_extension_hours,
        :season_period_days,
        :season_peak_day_of_year,
        :schedule_csv,
        :passes,
        :exceptions,
        :low_latency_enabled,
        :low_latency_capacity_fraction,
        :low_latency_periods,
    ),
    Tuple{
        Float64,
        Float64,
        Float64,
        String,
        Vector{ContactWindow},
        Dict{Date,Tuple{Time,Second}},
        Bool,
        Float64,
        Vector{ContactWindow},
    },
}

"""
    parsed_datetime(v, name::String) -> DateTime

Coerces a config value to `DateTime`: TOML local datetimes and dates arrive
already parsed, strings are read as ISO-8601; anything else is rejected
with a `[CONFIG]` error naming `name`.
"""
function parsed_datetime(v, name::String)
    v isa DateTime && return v
    v isa Date && return DateTime(v)
    v isa AbstractString ||
        config_error("[CONFIG] $name must be an ISO-8601 datetime (got $(repr(v))).")
    try
        return DateTime(v)
    catch
        config_error("[CONFIG] $name is not a parseable ISO-8601 datetime: $v")
    end
end

"""
    parsed_date(v, name::String) -> Date

Coerces a config value to `Date` (TOML local date, datetime, or ISO-8601
string) with a `[CONFIG]` error naming `name` otherwise.
"""
function parsed_date(v, name::String)
    v isa Date && return v
    v isa DateTime && return Date(v)
    v isa AbstractString ||
        config_error("[CONFIG] $name must be an ISO-8601 date (got $(repr(v))).")
    try
        return Date(v)
    catch
        config_error("[CONFIG] $name is not a parseable ISO-8601 date: $v")
    end
end

"""
    parsed_time(v, name::String) -> Time

Coerces a config value to `Time` (TOML local time or `HH:MM:SS` string) with
a `[CONFIG]` error naming `name` otherwise.
"""
function parsed_time(v, name::String)
    v isa Time && return v
    v isa AbstractString ||
        config_error("[CONFIG] $name must be a HH:MM:SS time (got $(repr(v))).")
    try
        return Time(v)
    catch
        config_error("[CONFIG] $name is not a parseable HH:MM:SS time: $v")
    end
end

hours_period(hours::Float64) = Millisecond(round(Int, 3_600_000 * hours))

"""
    contacts_settings(cfg::AbstractDict) -> ContactsSettings

Validated `[contacts]` section — the ground-contact schedule layered on the
daily window of `[telemetry]`; every key is optional and an absent section
reproduces the plain daily window.

  - `seasonal_extension_hours ≥ 0` (default 0): peak extension of the daily
    window, cosine-modulated over `season_period_days > 0` (default 365.25)
    and peaking at `season_peak_day_of_year ∈ [1, 366]` (default 172);
    `telemetry.session_duration_hours` plus the extension may not exceed
    24 h.
  - `[[contacts.passes]]` (`start` datetime, `duration_hours > 0`) or
    `schedule_csv` (columns `Start`, `DurationHours`; relative paths resolve
    against the current directory, then the project root) — an explicit,
    non-overlapping pass list that replaces the daily generator. The two
    forms are mutually exclusive.
  - `[[contacts.exceptions]]` (`date`, optional `start`, `duration_hours ∈
    [0, 24]`, `0` = missed pass): the window of that date verbatim, in
    place of the generated one; incompatible with an explicit schedule.
  - `low_latency_enabled` (default `true`), `low_latency_capacity_fraction
    ∈ (0, 1]` (default 1), and `[[contacts.low_latency_periods]]` (`start`,
    `duration_hours > 0`, optional `capacity_fraction`, `label`): extra
    contact windows at constant capacity outside the nominal passes.
    Periods triggered by `[[events.markers]]`
    ([`event_marker_settings`](@ref)) are appended, labelled by the marker.

Malformed entries raise a `[CONFIG]` error: a silently dropped pass or
period invalidates the scenario.
"""
function contacts_settings(cfg::AbstractDict)
    c = get(cfg, "contacts", Dict{String,Any}())
    tel = telemetry_settings(cfg)
    session_hours = tel.session_duration.value / 3600

    extension = checked_number(
        get(c, "seasonal_extension_hours", 0.0),
        "contacts.seasonal_extension_hours",
    )
    extension >= 0.0 || config_error(
        "[CONFIG] contacts.seasonal_extension_hours must be ≥ 0 (got $extension).",
    )
    session_hours + extension <= 24.0 || config_error(
        "[CONFIG] telemetry.session_duration_hours + contacts.seasonal_extension_hours = $(session_hours + extension) h exceeds 24 h.",
    )
    period =
        checked_number(get(c, "season_period_days", 365.25), "contacts.season_period_days")
    period > 0.0 ||
        config_error("[CONFIG] contacts.season_period_days must be > 0 (got $period).")
    peak = checked_number(
        get(c, "season_peak_day_of_year", 172.0),
        "contacts.season_peak_day_of_year",
    )
    1.0 <= peak <= 366.0 || config_error(
        "[CONFIG] contacts.season_peak_day_of_year must lie in [1, 366] (got $peak).",
    )

    schedule_csv = checked_string(get(c, "schedule_csv", ""), "contacts.schedule_csv")
    pass_entries = get(c, "passes", Any[])
    isempty(schedule_csv) ||
        isempty(pass_entries) ||
        config_error(
            "[CONFIG] contacts.schedule_csv and [[contacts.passes]] are mutually exclusive.",
        )
    passes = ContactWindow[]
    for (i, e) in enumerate(pass_entries)
        e isa AbstractDict ||
            config_error("[CONFIG] contacts.passes[$i] must be a table of pass keys.")
        start = parsed_datetime(get(e, "start", nothing), "contacts.passes[$i].start")
        hours = checked_number(
            get(e, "duration_hours", 0.0),
            "contacts.passes[$i].duration_hours",
        )
        hours > 0.0 || config_error(
            "[CONFIG] contacts.passes[$i].duration_hours must be > 0 (got $hours).",
        )
        push!(passes, ContactWindow(start, start + hours_period(hours)))
    end
    if !isempty(schedule_csv)
        path =
            isabspath(schedule_csv) || isfile(schedule_csv) ? schedule_csv :
            joinpath(PROJECT_ROOT, schedule_csv)
        isfile(path) || config_error("[CONFIG] contacts.schedule_csv not found: $path")
        df = CSV.read(path, DataFrame)
        for col in ("Start", "DurationHours")
            hasproperty(df, Symbol(col)) ||
                config_error("[CONFIG] contacts.schedule_csv lacks the column $col.")
        end
        for (i, r) in enumerate(eachrow(df))
            start = parsed_datetime(r.Start, "contacts.schedule_csv row $i Start")
            hours = checked_number(
                r.DurationHours,
                "contacts.schedule_csv row $i DurationHours",
            )
            hours > 0.0 || config_error(
                "[CONFIG] contacts.schedule_csv row $i DurationHours must be > 0 (got $hours).",
            )
            push!(passes, ContactWindow(start, start + hours_period(hours)))
        end
    end
    sort!(passes; by = w -> w.start)
    for i in 2:length(passes)
        passes[i].start >= passes[i-1].stop || config_error(
            "[CONFIG] contact passes overlap: $(passes[i-1].start) – $(passes[i-1].stop) and $(passes[i].start) – $(passes[i].stop).",
        )
    end

    exceptions = Dict{Date,Tuple{Time,Second}}()
    exception_entries = get(c, "exceptions", Any[])
    isempty(passes) ||
        isempty(exception_entries) ||
        config_error(
            "[CONFIG] [[contacts.exceptions]] modify the daily window and cannot combine with an explicit pass schedule.",
        )
    for (i, e) in enumerate(exception_entries)
        e isa AbstractDict || config_error(
            "[CONFIG] contacts.exceptions[$i] must be a table of exception keys.",
        )
        date = parsed_date(get(e, "date", nothing), "contacts.exceptions[$i].date")
        haskey(exceptions, date) &&
            config_error("[CONFIG] contacts.exceptions[$i] repeats the date $date.")
        start =
            parsed_time(get(e, "start", tel.session_start), "contacts.exceptions[$i].start")
        hours = checked_number(
            get(e, "duration_hours", session_hours),
            "contacts.exceptions[$i].duration_hours",
        )
        0.0 <= hours <= 24.0 || config_error(
            "[CONFIG] contacts.exceptions[$i].duration_hours must lie in [0, 24] (got $hours).",
        )
        exceptions[date] = (start, Second(round(Int, 3600 * hours)))
    end

    enabled =
        checked_flag(get(c, "low_latency_enabled", true), "contacts.low_latency_enabled")
    default_fraction = checked_number(
        get(c, "low_latency_capacity_fraction", 1.0),
        "contacts.low_latency_capacity_fraction",
    )
    0.0 < default_fraction <= 1.0 || config_error(
        "[CONFIG] contacts.low_latency_capacity_fraction must lie in (0, 1] (got $default_fraction).",
    )
    periods = ContactWindow[]
    for (i, e) in enumerate(get(c, "low_latency_periods", Any[]))
        e isa AbstractDict || config_error(
            "[CONFIG] contacts.low_latency_periods[$i] must be a table of period keys.",
        )
        start = parsed_datetime(
            get(e, "start", nothing),
            "contacts.low_latency_periods[$i].start",
        )
        hours = checked_number(
            get(e, "duration_hours", 0.0),
            "contacts.low_latency_periods[$i].duration_hours",
        )
        hours > 0.0 || config_error(
            "[CONFIG] contacts.low_latency_periods[$i].duration_hours must be > 0 (got $hours).",
        )
        fraction = checked_number(
            get(e, "capacity_fraction", default_fraction),
            "contacts.low_latency_periods[$i].capacity_fraction",
        )
        0.0 < fraction <= 1.0 || config_error(
            "[CONFIG] contacts.low_latency_periods[$i].capacity_fraction must lie in (0, 1] (got $fraction).",
        )
        label =
            checked_string(get(e, "label", ""), "contacts.low_latency_periods[$i].label")
        push!(
            periods,
            ContactWindow(start, start + hours_period(hours), fraction, true, label),
        )
    end
    for m in event_marker_settings(cfg)
        m.low_latency_duration_hours > 0.0 || continue
        start = m.time + hours_period(m.low_latency_after_hours)
        fraction =
            isnan(m.low_latency_capacity_fraction) ? default_fraction :
            m.low_latency_capacity_fraction
        push!(
            periods,
            ContactWindow(
                start,
                start + hours_period(m.low_latency_duration_hours),
                fraction,
                true,
                m.label,
            ),
        )
    end
    sort!(periods; by = w -> w.start)

    return (
        seasonal_extension_hours = extension,
        season_period_days = period,
        season_peak_day_of_year = peak,
        schedule_csv = schedule_csv,
        passes = passes,
        exceptions = exceptions,
        low_latency_enabled = enabled,
        low_latency_capacity_fraction = default_fraction,
        low_latency_periods = periods,
    )
end

"""
    validate_config(cfg::AbstractDict)

Validates every tunable against its safe interval (documented inline in
`config.toml`) before any directory is created or any computation starts.
Code-breaking values are rejected with an `ArgumentError` (early
termination); suspicious but
runnable values emit a `@warn`. Returns `cfg` for chaining.

Hard errors (would break the pipeline):
  - non-positive `speed_up`, `mission_wall_seconds`, `sample_rate`,
    `segment_duration_sec`, `max_batches_per_hour`, `max_storage_gb`
  - `batch_size < 1`, `initial_downtime_days < 0`
  - `session_duration_hours` outside `(0, 24]` (the daily session scheduler
    wraps `Time` arithmetic at 24 h)
  - fewer than 2 samples per segment (`sample_rate * segment_duration_sec < 2`
    breaks the FFT synthesis block)
  - unknown `data_source`; `data_source = "external"` with a missing file
  - packet-loss probabilities outside `[0, 1]`, unknown loss `model` or
    `on_loss` policy, negative `max_retries`
  - disruption events with negative `start_day`, non-positive `duration_hours`,
    negative `recovery_hours`, or `severity` outside `[0, 1]`
  - type-mismatched values anywhere (a quoted `"3600"` where a number is
    expected, a float where an integer is expected) — reported as a precise
    `[CONFIG]` message instead of a raw conversion stacktrace

Warnings (runnable but likely unintended):
  - emitter wall-clock period `segment_duration_sec / speed_up` below 5 ms
    (the generation loop cannot keep pace; sim-time desync)
  - receiver nominal download slot `3600 / (max_batches_per_hour · speed_up)`
    below 2 ms (the 1 ms sleep floor distorts the download rate)
  - unknown `bandwidth_profile` (falls back to `"sine"`)
  - the physical rate pair combined with a shaped `bandwidth_profile` (the
    profile mean scales a link rate that the pass sustains; the capacity of
    one nominal pass against the daily production is stated)
  - non-integer `sample_rate * segment_duration_sec` (rounded)
  - Gilbert–Elliott `p_bad_to_good = 0` (the channel never recovers)
  - disruption events starting at or after mission end (never fire), events
    whose blackout + recovery tail is truncated by mission end, blackouts
    spanning the entire remaining mission, and events overlapping in time
    (capacity composes as the minimum, loss multiplier as the maximum)
  - unrecognized sections or keys anywhere in the config (typo guard — an
    unknown key would otherwise silently fall back to its default)
  - loss saturation — the worst-channel-state per-attempt loss composed with
    the largest disruption `loss_multiplier` reaches ≥ 1 (every transfer
    fails while that regime is active)
"""
function validate_config(cfg::AbstractDict)
    # Unrecognized-key sweep (silent-failure guard): a mistyped key would
    # otherwise fall back to a default without a trace.
    for (section, content) in cfg
        if !haskey(KNOWN_CONFIG_KEYS, section)
            @warn "[CONFIG] Unrecognized section [$section] — its keys are ignored (typo?)."
        elseif section != "provenance" && content isa AbstractDict
            for key in keys(content)
                key in KNOWN_CONFIG_KEYS[section] ||
                    @warn "[CONFIG] Unrecognized key $section.$key — ignored (typo?)."
            end
        end
    end
    for (i, e) in enumerate(
        get(
            get(cfg, "disruption", get(cfg, "disaster", Dict{String,Any}())),
            "events",
            Any[],
        ),
    )
        e isa AbstractDict || continue
        for key in keys(e)
            key in KNOWN_EVENT_KEYS ||
                @warn "[CONFIG] Unrecognized key disruption.events[$i].$key — ignored (typo?)."
        end
    end
    for (i, e) in enumerate(get(get(cfg, "events", Dict{String,Any}()), "markers", Any[]))
        e isa AbstractDict || continue
        for key in keys(e)
            key in KNOWN_MARKER_KEYS ||
                @warn "[CONFIG] Unrecognized key events.markers[$i].$key — ignored (typo?)."
        end
    end
    contacts_section = get(cfg, "contacts", Dict{String,Any}())
    for (list, known) in KNOWN_CONTACT_ENTRY_KEYS
        for (i, e) in enumerate(get(contacts_section, list, Any[]))
            e isa AbstractDict || continue
            for key in keys(e)
                key in known ||
                    @warn "[CONFIG] Unrecognized key contacts.$list[$i].$key — ignored (typo?)."
            end
        end
    end

    sim = get(cfg, "simulation", Dict{String,Any}())
    tel = get(cfg, "telemetry", Dict{String,Any}())
    phy = get(cfg, "physics", Dict{String,Any}())

    # Required keys (R1 policy): a missing core tunable is a configuration
    # error, never a silently invented default.
    for (section, sec_name, required) in (
        (sim, "simulation", ("speed_up", "start_sim_time")),
        (tel, "telemetry", ("session_start", "session_duration_hours")),
        (
            phy,
            "physics",
            ("data_source", "sample_rate", "segment_duration_sec", "batch_size"),
        ),
    )
        for key in required
            haskey(section, key) ||
                config_error("[CONFIG] Missing required key $sec_name.$key.")
        end
    end

    haskey(tel, "max_batches_per_hour") ||
        (haskey(tel, "downlink_kbps") && haskey(tel, "onboard_data_rate_kbps")) ||
        config_error(
            "[CONFIG] Missing link capacity: give telemetry.max_batches_per_hour or the pair telemetry.downlink_kbps + telemetry.onboard_data_rate_kbps.",
        )

    # -- [simulation] --
    speed_up = checked_number(get(sim, "speed_up", 0.0), "simulation.speed_up")
    speed_up > 0.0 ||
        config_error("[CONFIG] simulation.speed_up must be > 0 (got $speed_up).")
    mission_wall_sec = mission_wall_seconds(cfg)
    downtime = checked_number(
        get(sim, "initial_downtime_days", 0.0),
        "simulation.initial_downtime_days",
    )
    downtime >= 0.0 || config_error(
        "[CONFIG] simulation.initial_downtime_days must be ≥ 0 (got $downtime).",
    )
    # Budget positivity is checked through storage_budget so both the
    # [storage] location and the deprecated [simulation] fallback are covered.
    max_gb = storage_budget(cfg).max_gb
    max_gb > 0.0 ||
        config_error("[CONFIG] storage.max_storage_gb must be > 0 (got $max_gb).")
    haskey(sim, "start_sim_time") ||
        config_error("[CONFIG] simulation.start_sim_time is required.")
    try
        DateTime(sim["start_sim_time"])
    catch
        config_error(
            "[CONFIG] simulation.start_sim_time is not a parseable ISO datetime: $(sim["start_sim_time"])",
        )
    end
    seed = get(sim, "rng_seed", 0)
    (seed isa Integer && !(seed isa Bool)) ||
        config_error("[CONFIG] simulation.rng_seed must be an integer (got $(repr(seed))).")

    # -- [physics] --
    # Types, bounds, and the enumeration through the shared accessor; the
    # rounding warning and the input-file existence check live here.
    physics = physics_settings(cfg)
    seg_dur = physics.segment_duration_sec
    n_samples = physics.sample_rate * seg_dur
    if !isapprox(n_samples, round(n_samples); atol = 1e-9)
        @warn "[CONFIG] sample_rate × segment_duration_sec = $n_samples is not an integer; segment length is rounded to $(round(Int, n_samples)) samples."
    end
    if physics.data_source == "external"
        ext_path =
            isabspath(physics.external_data_path) ? physics.external_data_path :
            joinpath(PROJECT_ROOT, physics.external_data_path)
        isfile(ext_path) || config_error(
            "[CONFIG] physics.data_source = \"external\" but external_data_path not found: $ext_path",
        )
    end

    # -- [telemetry] --
    # Types and bounds are enforced by the shared accessor (also consumed by
    # the link builder, the receiver, and the entry point); only the
    # non-fatal profile check lives here.
    tel_settings = telemetry_settings(cfg)
    tel_settings.bandwidth_profile in ("sine", "sigmoid", "gaussian", "flat") ||
        @warn "[CONFIG] Unknown telemetry.bandwidth_profile = \"$(tel_settings.bandwidth_profile)\"; falling back to \"sine\"."
    # A physical link rate is sustained across the pass; a shaped profile
    # scales it by the profile mean and the daily balance changes regime.
    balance = capacity_balance(cfg)
    if balance.rate_form && tel_settings.bandwidth_profile != "flat"
        @warn "[CONFIG] telemetry.downlink_kbps / onboard_data_rate_kbps state a physical link rate, which the pass sustains, " *
              "but telemetry.bandwidth_profile = \"$(tel_settings.bandwidth_profile)\" scales it by the pass profile " *
              "(mean $(round(balance.profile_mean, digits = 2)) over the pass): " *
              "$(round(Int, balance.capacity_per_pass)) batches per $(balance.pass_hours) h nominal pass against " *
              "$(round(Int, balance.produced_per_day)) produced per day. Use \"flat\" for the physical link; " *
              "a shaped profile with max_batches_per_hour is the abstraction of a partially usable pass."
    end

    # -- Real-time pacing sanity (loop-scheduler corner cases) --
    emitter_period_ms = seg_dur / speed_up * 1000.0
    if emitter_period_ms < 5.0
        @warn "[CONFIG] Emitter wall-clock period is $(round(emitter_period_ms, digits=2)) ms " *
              "(segment_duration_sec / speed_up). Below ~5 ms the generation loop cannot keep " *
              "pace with the accelerated clock and batch timestamps desynchronize. " *
              "Increase segment_duration_sec or decrease speed_up."
    end
    rx_slot_ms = tel_settings.nominal_batch_transfer_sec / speed_up * 1000.0
    if rx_slot_ms < 2.0
        @warn "[CONFIG] Receiver download slot is $(round(rx_slot_ms, digits=2)) ms " *
              "(batch transfer time / speed_up). The $(RECEIVER_SLEEP_FLOOR_SEC * 1000) ms sleep floor distorts " *
              "the effective downlink rate. Decrease speed_up or the link capacity."
    end
    # -- [contacts], [[events.markers]], [ground], [post_processing.publication] --
    contacts_settings(cfg)
    ground_settings(cfg)
    publication_settings(cfg)

    # -- on-board recorder against the contact schedule --
    capacity = onboard_capacity(cfg)
    if downtime > capacity.days
        @warn "[CONFIG] simulation.initial_downtime_days = $downtime exceeds the on-board recorder capacity ($(capacity.days) days): pre-populated batches beyond $(capacity.batches) are discarded."
    end
    mission_days = mission_wall_seconds(cfg) * speed_up / 86_400
    t_start = DateTime(sim["start_sim_time"])
    windows = contact_windows(
        visibility_model(cfg),
        t_start,
        t_start + Millisecond(round(Int, mission_days * 86_400_000)),
    )
    t_end = t_start + Millisecond(round(Int, mission_days * 86_400_000))
    longest_gap_hours = 0.0
    previous_stop = t_start - Millisecond(round(Int, downtime * 86_400_000))
    for w in windows
        longest_gap_hours = max(longest_gap_hours, (w.start - previous_stop).value / 3.6e6)
        previous_stop = max(previous_stop, w.stop)
    end
    # Data produced after the last contact accumulates until the mission end.
    longest_gap_hours = max(longest_gap_hours, (t_end - previous_stop).value / 3.6e6)
    if longest_gap_hours > 24 * capacity.days
        @warn "[CONFIG] The longest interval without ground contact ($(round(longest_gap_hours, digits = 1)) h) exceeds the on-board recorder capacity ($(24 * capacity.days) h of production): the emitter discards data once the buffer is full."
    end

    # -- [packet_loss] --
    # Types, enumerations, and bounds are enforced by the shared accessor
    # regardless of `enabled`: a malformed-but-disabled section must fail
    # fast, not lie dormant. Only the cross-key physics warnings live here.
    loss = loss_channel_settings(cfg)
    events = disruption_event_settings(cfg)
    if loss.enabled
        if loss.model == "gilbert_elliott" && loss.p_bad_to_good == 0.0
            @warn "[CONFIG] packet_loss.p_bad_to_good = 0: once the channel enters the BAD state it never recovers."
        end
        # Saturation: the worst-channel-state per-attempt loss composed with
        # the largest disruption loss multiplier. At or above 1, every
        # transfer fails while that regime is active.
        p_worst = loss.model == "gilbert_elliott" ? loss.p_loss_bad : loss.p_loss
        max_mult = maximum((ev.loss_multiplier for ev in events); init = 1.0)
        if p_worst * max_mult >= 1.0
            regime =
                max_mult > 1.0 ?
                "while a disruption loss multiplier (× $max_mult) is active" :
                "at all times"
            @warn "[CONFIG] Loss saturation: worst-state per-attempt loss $p_worst × multiplier reaches ≥ 1 — every transfer fails $regime; affected batches exhaust max_retries and land in lost/."
        end
    end

    # -- [disruption] --
    haskey(cfg, "disaster") &&
        !haskey(cfg, "disruption") &&
        @warn "[CONFIG] The [disaster] section name is deprecated — rename it to [disruption]."
    mission_days = mission_wall_sec * speed_up / 86_400.0
    event_windows = Tuple{Float64,Float64,Int}[] # (start_h, end_h incl. ramp, event index)
    for (i, ev) in enumerate(events)
        ev.loss_multiplier >= 1.0 ||
            @warn "[CONFIG] disruption.events[$i].loss_multiplier < 1 reduces loss during the event."
        end_h = ev.start_day * 24.0 + ev.duration_hours + ev.recovery_hours
        if ev.start_day >= mission_days
            # Inclusive boundary: an event at the exact final instant is
            # never simulated either.
            @warn "[CONFIG] disruption.events[$i] starts on mission day $(ev.start_day) but the mission spans only $(round(mission_days, digits=2)) days: the event never fires."
        elseif ev.severity >= 1.0 &&
               ev.start_day * 24.0 + ev.duration_hours >= mission_days * 24.0
            @warn "[CONFIG] disruption.events[$i] blacks out the link from day $(ev.start_day) to mission end: no batch after the event onset will ever reach the ground."
        elseif end_h > mission_days * 24.0
            @warn "[CONFIG] disruption.events[$i] extends beyond mission end (blackout + recovery reach day $(round(end_h / 24.0, digits=2)) of $(round(mission_days, digits=2))): the tail is truncated and never observed."
        end
        push!(event_windows, (ev.start_day * 24.0, end_h, i))
    end
    sort!(event_windows, by = first)
    for k in 2:length(event_windows)
        (_, end_prev, i_prev) = event_windows[k-1]
        (start_k, _, i_k) = event_windows[k]
        if start_k < end_prev
            @warn "[CONFIG] disruption.events[$i_prev] and disruption.events[$i_k] overlap in time: link capacity composes as the minimum over active events and the loss multiplier as their maximum — verify this is the intended physics."
        end
    end

    # -- [storage] --
    st = get(cfg, "storage", Dict{String,Any}())
    for key in (
        "max_storage_gb",
        "max_ram_gb",
        String.(collect(keys(STORAGE_CALIBRATION_DEFAULTS)))...,
    )
        if haskey(st, key)
            v = checked_number(st[key], "storage.$key")
            v > 0.0 || config_error("[CONFIG] storage.$key must be > 0 (got $v).")
        end
    end
    if haskey(st, "max_file_count")
        nf = checked_integer(st["max_file_count"], "storage.max_file_count")
        nf > 0 || config_error("[CONFIG] storage.max_file_count must be > 0 (got $nf).")
    end

    # -- [supervision] --
    supervision_settings(cfg)

    # -- [dashboard] / [post_processing] --
    db = get(cfg, "dashboard", Dict{String,Any}())
    for key in ("open_live_viewer", "open_receiver_log", "open_emitter_log")
        haskey(db, key) && checked_flag(db[key], "dashboard.$key")
    end
    pp = get(cfg, "post_processing", Dict{String,Any}())
    for key in (
        "generate_mask_timeline",
        "generate_batch_matrix",
        "expand_to_pointwise_masks",
        "alert_latency",
        "delivery_delay",
        "hdf5_export",
    )
        haskey(pp, key) && checked_flag(pp[key], "post_processing.$key")
    end
    for (key, label) in (
        ("alert_lookback_hours", "look-back"),
        ("delivery_requirement_hours", "delivery requirement"),
    )
        haskey(pp, key) || continue
        v = checked_number(pp[key], "post_processing.$key")
        v > 0.0 || config_error("[CONFIG] post_processing.$key must be > 0 (got $v).")
    end
    # Canonicalization warns on unrecognized entries at validation time, not
    # first at estimation/expansion time.
    haskey(pp, "target_event_rows") && normalize_target_rows(pp["target_event_rows"])

    # -- [retention] --
    ret = get(cfg, "retention", Dict{String,Any}())
    if !isempty(ret)
        en = get(ret, "enabled", false)
        en isa Bool ||
            config_error("[CONFIG] retention.enabled must be a boolean (got $(repr(en))).")
        for key in ("grace_hours", "high_watermark_gb", "log_rotate_mb")
            if haskey(ret, key)
                v = checked_number(ret[key], "retention.$key")
                v > 0.0 || config_error("[CONFIG] retention.$key must be > 0 (got $v).")
            end
        end
        if haskey(ret, "high_watermark_gb")
            budget = storage_budget(cfg)
            wm = Float64(ret["high_watermark_gb"])
            wm <= budget.max_gb || config_error(
                "[CONFIG] retention.high_watermark_gb = $wm exceeds the storage budget ($(budget.max_gb) GB): the custodian would never trigger below the abort threshold.",
            )
        end
    end

    return cfg
end

# --- Storage Governance (pre-run safety gate + retention settings) ---

"""
    RECEIVER_POLL_INTERVAL_SEC

Receiver idle-poll / metrics-tick interval [wall-clock s]. Shared between the
receiver loop and the artifact estimator so the metrics-row upper bound and
the realized sampling cadence cannot drift apart.
"""
const RECEIVER_POLL_INTERVAL_SEC = 0.2

"""
    METRICS_BANDWIDTH_HYSTERESIS_PCT

Bandwidth change [percentage points] that admits a new `mission_profile.csv`
row. Shared between the receiver's metrics write gate and the artifact
estimator so the metrics-row bound and the realized sampling cadence cannot
drift apart.
"""
const METRICS_BANDWIDTH_HYSTERESIS_PCT = 0.1

"""
    RECEIVER_SLEEP_FLOOR_SEC

Minimum receiver download-slot sleep [s] — an OS scheduler property, not a
tunable. Shared between the receiver loop and the validator warning about
download-rate distortion so the two can never drift apart.
"""
const RECEIVER_SLEEP_FLOOR_SEC = 0.001

"""
    EMITTER_MAX_SLEEP_SEC

Upper bound on a single emitter pacing sleep [wall-clock s]. The generation
loop wakes at least this often to refresh its heartbeat and to honor the
stop flag, the `HALT` sentinel, and the deadline even when one segment
period is long (real-time rehearsals at low `speed_up`).
"""
const EMITTER_MAX_SLEEP_SEC = 0.5

"""
    EMITTER_LAG_WARN_SEC

Wall-clock duration [s] for which the emitter's content lag must persist
above one segment period before the loop warns that the host cannot keep
pace with the accelerated clock. Startup compilation and transient stalls
are recovered by burst catch-up within this window and never warn.
"""
const EMITTER_LAG_WARN_SEC = 5.0

"""
    thread_advisory() -> Union{Nothing, String}

Returns an advisory message when the process runs on a single Julia thread,
`nothing` otherwise. The emitter, the receiver, and the supervisor are
cooperative tasks: on one thread any non-yielding stretch in one of them
(compilation warm-up, garbage collection, figure rendering) pauses the
others until it yields. Three threads let each task own one; more bring no
benefit because nothing else in the pipeline is parallel.
"""
function thread_advisory()
    Threads.nthreads() >= 2 && return nothing
    return "[THREADS] Running on a single Julia thread: the emitter, receiver, and " *
           "supervisor share it cooperatively, so compilation warm-up, GC, and figure " *
           "rendering in one component pause the others. Launch with `julia --threads=3` " *
           "(or `auto`) for an independent thread per component."
end

"""
    DEFAULT_WATERMARK_FRACTION

Fraction of the storage budget at which the retention custodian begins
pruning when `retention.high_watermark_gb` is not configured explicitly.
"""
const DEFAULT_WATERMARK_FRACTION = 0.75

"""
    STORAGE_WARN_FRACTION

Fraction of a `[storage]` budget above which the pre-run gate warns without
aborting.
"""
const STORAGE_WARN_FRACTION = 0.9

"""
    MASK_ROW_OVERHEAD_BYTES

Estimator calibration: fixed per-row overhead of the mask-timeline CSV
(timestamp column + separators) beyond its per-batch cells.
"""
const MASK_ROW_OVERHEAD_BYTES = 32.0

"""
    LOG_FIXED_OVERHEAD_BYTES

Estimator calibration: mission-level fixed size of the emitter and receiver
text logs (banners, startup and post-processing records) independent of the
batch count.
"""
const LOG_FIXED_OVERHEAD_BYTES = 200_000.0

"""
    RUN_FILE_COUNT_SLACK

Estimator calibration: fixed file-count slack for rotation backups and
sentinel files beyond the per-class counts.
"""
const RUN_FILE_COUNT_SLACK = 8

"""
    storage_budget(cfg::AbstractDict) -> (max_gb, max_files, max_ram_gb)

Resolves the run-directory disk budget [GB] and inode budget from `[storage]`.
`simulation.max_storage_gb` is honored as a deprecated fallback (with a
warning); with neither present the legacy default of 5.0 GB applies.
`max_ram_gb` (default 8.0) budgets the post-processing replay RAM.
"""
function storage_budget(cfg::AbstractDict)
    st = get(cfg, "storage", Dict{String,Any}())
    sim = get(cfg, "simulation", Dict{String,Any}())
    max_gb = if haskey(st, "max_storage_gb")
        checked_number(st["max_storage_gb"], "storage.max_storage_gb")
    elseif haskey(sim, "max_storage_gb")
        @warn "[CONFIG] simulation.max_storage_gb is deprecated — move the key to [storage]." maxlog =
            1
        checked_number(sim["max_storage_gb"], "simulation.max_storage_gb")
    else
        5.0
    end
    max_files =
        checked_integer(get(st, "max_file_count", 1_000_000), "storage.max_file_count")
    max_ram_gb = checked_number(get(st, "max_ram_gb", 8.0), "storage.max_ram_gb")
    return (max_gb = max_gb, max_files = max_files, max_ram_gb = max_ram_gb)
end

"""
    RetentionPolicy

Immutable operating parameters of the retention custodian: `enabled`,
`grace` (the mission-time availability guarantee for delivered payloads, as
a `Millisecond` period), `watermark_bytes` (prunable-payload size that
triggers pruning), and `log_rotate_bytes` (size-capped log rotation, active
regardless of `enabled`). Constructed by [`retention_settings`](@ref).
"""
struct RetentionPolicy
    enabled::Bool
    grace::Millisecond
    watermark_bytes::Float64
    log_rotate_bytes::Float64
end

"""
    retention_settings(cfg::AbstractDict) -> RetentionPolicy

Parses the `[retention]` section into a [`RetentionPolicy`](@ref):
`retention.grace_hours` converts to a `Millisecond` period at parse time,
and `high_watermark_gb` defaults to 75 % of the storage budget.
"""
function retention_settings(cfg::AbstractDict)
    ret = get(cfg, "retention", Dict{String,Any}())
    enabled = checked_flag(get(ret, "enabled", false), "retention.enabled")
    grace_hours = checked_number(get(ret, "grace_hours", 24.0), "retention.grace_hours")
    default_wm = DEFAULT_WATERMARK_FRACTION * storage_budget(cfg).max_gb
    watermark_gb = checked_number(
        get(ret, "high_watermark_gb", default_wm),
        "retention.high_watermark_gb",
    )
    rotate_mb = checked_number(get(ret, "log_rotate_mb", 64.0), "retention.log_rotate_mb")
    return RetentionPolicy(
        enabled,
        Millisecond(round(Int, grace_hours * 3_600_000)),
        watermark_gb * 1024^3,
        rotate_mb * 1024^2,
    )
end

"""
    estimate_artifacts(cfg::AbstractDict) -> NamedTuple

Closed-form per-class artifact estimate for a run, computed entirely from the
configuration (upper bounds where exact counts depend on stochastic outcomes).
Classes: payload segment CSVs, batch metadata, event logs, metrics, the 2D
mask timeline, point-wise expansions, plots (session + summary figures, PNG
and vector-PDF twins; the optional GIF is a manual post-processing product
and is excluded), and text logs. `replay_ram_bytes` estimates the
post-processing replay RAM (gated against `storage.max_ram_gb`). Calibration constants default to measured values and are overridable
key-by-key in `[storage]`.

Returns counts (`n_segments`, `n_batches`, `n_points`, `mission_days`,
`metrics_rows`), per-class byte fields, `total_bytes`, `file_count`, and the
retention-prunable subset (`prunable_bytes`, `prunable_files`): the payload
scaled by the expected *delivered* fraction under the configured loss model —
terminally lost batches land in `lost/`, and metadata, event logs, metrics,
masks, and `lost/` are never prunable by construction.
"""
function estimate_artifacts(cfg::AbstractDict)
    sim = get(cfg, "simulation", Dict{String,Any}())
    phy = get(cfg, "physics", Dict{String,Any}())
    st = get(cfg, "storage", Dict{String,Any}())

    speed_up =
        checked_number(required_value(sim, "simulation", "speed_up"), "simulation.speed_up")
    mission_wall_sec = mission_wall_seconds(cfg)
    seg_dur = checked_number(
        required_value(phy, "physics", "segment_duration_sec"),
        "physics.segment_duration_sec",
    )
    sr =
        checked_number(required_value(phy, "physics", "sample_rate"), "physics.sample_rate")
    batch_sz = checked_integer(get(phy, "batch_size", 15), "physics.batch_size")
    downtime_days = checked_number(
        get(sim, "initial_downtime_days", 0.0),
        "simulation.initial_downtime_days",
    )

    loss = loss_channel_settings(cfg)
    loss_enabled = loss.enabled
    retries = loss.enabled ? loss.max_retries : 0

    cal =
        key -> Float64(get(st, key, getproperty(STORAGE_CALIBRATION_DEFAULTS, Symbol(key))))

    sim_sec = mission_wall_sec * speed_up
    total_sec_gen = sim_sec + downtime_days * 86_400.0
    n_segments = ceil(Int, total_sec_gen / seg_dur)
    n_batches = ceil(Int, n_segments / batch_sz)
    n_points = round(Int, n_segments * seg_dur * sr)
    mission_days = ceil(Int, sim_sec / 86_400.0)
    # Metrics rows are admitted on batch-count changes (≤ 4 per batch:
    # onboard, link, and ground/lost transitions plus slack) and on
    # bandwidth-hysteresis steps — one full 0 → peak → 0 pass admits up to
    # 2 × 100 / hysteresis rows per mission day.
    metrics_rows =
        4 * n_batches +
        2 * round(Int, 100.0 / METRICS_BANDWIDTH_HYSTERESIS_PCT) * max(mission_days, 1)

    payload_bytes = n_points * cal("bytes_per_sample")
    batch_meta_bytes = n_batches * cal("bytes_batch_metadata")
    # tx: gen + tx per batch; rx worst case: `retries` retry rows + one
    # terminal (ingested | lost) + one potential pruned row.
    event_bytes = (2 * n_batches + n_batches * (retries + 2)) * cal("bytes_event_row")
    metrics_bytes = metrics_rows * cal("bytes_metrics_row")

    pp = get(cfg, "post_processing", Dict{String,Any}())
    do_matrix = checked_flag(
        aliased_value(
            pp,
            "post_processing",
            "generate_mask_timeline",
            "generate_batch_matrix",
            true,
        ),
        "post_processing.generate_mask_timeline",
    )
    mask_bytes =
        do_matrix ?
        metrics_rows * (n_batches * cal("bytes_mask_cell") + MASK_ROW_OVERHEAD_BYTES) : 0.0

    do_expand = checked_flag(
        get(pp, "expand_to_pointwise_masks", false),
        "post_processing.expand_to_pointwise_masks",
    )
    target_rows = normalize_target_rows(get(pp, "target_event_rows", [-1]))
    # Branch on the concrete type: the union contract admits any Symbol, so a
    # type test narrows soundly where `=== :all` would not.
    n_expansions =
        do_expand ? (target_rows isa Vector{Int} ? length(target_rows) : metrics_rows) : 0
    pointwise_bytes = n_expansions * n_points * cal("bytes_pointwise_cell")
    # HDF5 export: a second copy of the tabular products and masks (the
    # binary layout is denser than CSV; the CSV sizes bound it).
    hdf5_bytes =
        checked_flag(get(pp, "hdf5_export", false), "post_processing.hdf5_export") ?
        event_bytes + metrics_bytes + mask_bytes + pointwise_bytes : 0.0

    # Mission summary, one session figure per day and per low-latency
    # period, the two metric figures.
    n_low_latency = length(contacts_settings(cfg).low_latency_periods)
    plot_bytes =
        (mission_days + 3 + n_low_latency) * (cal("bytes_plot") + cal("bytes_plot_pdf"))
    log_bytes = n_batches * cal("bytes_log_per_batch") + LOG_FIXED_OVERHEAD_BYTES

    # Post-processing replay RAM: the exact replay materializes one category
    # membership per (metrics row x batch); the GIF is a manual product and
    # is excluded, matching the plots policy above.
    replay_ram_bytes =
        (do_matrix || do_expand) ? metrics_rows * n_batches * cal("bytes_replay_cell") : 0.0

    total_bytes =
        payload_bytes +
        batch_meta_bytes +
        event_bytes +
        metrics_bytes +
        mask_bytes +
        pointwise_bytes +
        hdf5_bytes +
        plot_bytes +
        log_bytes

    # Files: per batch one directory, one metadata.json, batch_sz segment CSVs;
    # plus event logs, profile, mask products, plots, logs, snapshot, sentinels
    # and the six run subdirectories (small fixed slack for rotations).
    file_count =
        n_batches * (batch_sz + 2) +
        2 +
        1 +
        (do_matrix ? 1 : 0) +
        n_expansions +
        2 * (mission_days + 3 + n_low_latency) +
        (hdf5_bytes > 0 ? 1 : 0) +
        2 +
        1 +
        2 +
        6 +
        RUN_FILE_COUNT_SLACK

    # Retention-prunable subset: delivered payload CSVs only. Batches that
    # terminally exhaust their retry budget land in lost/ (never prunable);
    # the expected terminal-loss fraction follows from the configured loss
    # model (per-attempt rate p_eff; retransmit → p_eff^(max_retries + 1),
    # drop → p_eff).
    p_eff = if !loss.enabled
        0.0
    elseif loss.model == "gilbert_elliott"
        denom = loss.p_good_to_bad + loss.p_bad_to_good
        pi_bad = denom > 0.0 ? loss.p_good_to_bad / denom : 0.0
        pi_bad * loss.p_loss_bad + (1.0 - pi_bad) * loss.p_loss_good
    else
        loss.p_loss
    end
    lost_fraction = loss.on_loss == "drop" ? p_eff : p_eff^(retries + 1)
    delivered_fraction = 1.0 - lost_fraction

    return (
        n_segments = n_segments,
        n_batches = n_batches,
        n_points = n_points,
        mission_days = mission_days,
        metrics_rows = metrics_rows,
        payload_bytes = payload_bytes,
        batch_meta_bytes = batch_meta_bytes,
        event_bytes = event_bytes,
        metrics_bytes = metrics_bytes,
        hdf5_bytes = hdf5_bytes,
        mask_bytes = mask_bytes,
        pointwise_bytes = pointwise_bytes,
        plot_bytes = plot_bytes,
        log_bytes = log_bytes,
        total_bytes = total_bytes,
        file_count = file_count,
        replay_ram_bytes = replay_ram_bytes,
        prunable_bytes = payload_bytes * delivered_fraction,
        prunable_files = round(Int, n_segments * delivered_fraction),
    )
end

"""
    check_storage_limits(cfg::AbstractDict)

Pre-run storage safety gate. Prints the per-class artifact estimate
([`estimate_artifacts`](@ref)), then enforces the `[storage]` budgets with
mitigation awareness:

  - retention disabled: abort when the projected total exceeds the budget
    (the error names `[retention]` as the mitigation); warn within 10 % of it.
  - retention enabled: abort only when even the steady-state footprint
    (non-prunable classes + payload capped at the watermark) exceeds the
    budget; otherwise warn if the unbounded projection exceeds the budget and
    proceed. Additionally warns when the payload generated within one
    `grace_hours` window alone exceeds the watermark (the custodian could
    never satisfy both constraints simultaneously).

The same logic gates `storage.max_file_count`, and the post-processing
replay RAM estimate is gated against `storage.max_ram_gb` (a mitigation-free
hard budget). Returns `nothing`; called before any run directory is created.
"""
function check_storage_limits(cfg::AbstractDict)
    est = estimate_artifacts(cfg)
    budget = storage_budget(cfg)
    ret = retention_settings(cfg)
    to_gb = b -> round(b / 1024^3, digits = 4)

    @info "[STORAGE] Pre-run artifact estimate ($(est.n_segments) segments, $(est.n_batches) batches, $(est.mission_days) mission days):"
    @info "  -> Payload segment CSVs: $(to_gb(est.payload_bytes)) GB ($(est.n_points) samples)"
    @info "  -> Batch metadata:       $(to_gb(est.batch_meta_bytes)) GB"
    @info "  -> Event logs:           $(to_gb(est.event_bytes)) GB"
    @info "  -> Metrics profile:      $(to_gb(est.metrics_bytes)) GB (≤ $(est.metrics_rows) rows)"
    est.mask_bytes > 0 && @info "  -> Mask timeline:        $(to_gb(est.mask_bytes)) GB"
    est.pointwise_bytes > 0 &&
        @info "  -> Point-wise masks:     $(to_gb(est.pointwise_bytes)) GB"
    @info "  -> Plots:                $(to_gb(est.plot_bytes)) GB"
    @info "  -> Logs:                 $(to_gb(est.log_bytes)) GB"
    @info "  -> Total:                $(to_gb(est.total_bytes)) GB, ≈ $(est.file_count) files (budget: $(budget.max_gb) GB, $(budget.max_files) files)"
    est.replay_ram_bytes > 0 &&
        @info "  -> Replay RAM:           $(to_gb(est.replay_ram_bytes)) GB (budget: $(budget.max_ram_gb) GB)"

    max_ram_bytes = budget.max_ram_gb * 1024^3
    if est.replay_ram_bytes > max_ram_bytes
        error(
            "[STORAGE] Post-processing replay RAM estimate ($(to_gb(est.replay_ram_bytes)) GB) exceeds storage.max_ram_gb ($(budget.max_ram_gb) GB). Reduce the mission span, disable post_processing.generate_batch_matrix, or raise storage.max_ram_gb.",
        )
    elseif est.replay_ram_bytes > STORAGE_WARN_FRACTION * max_ram_bytes
        @warn "[STORAGE] Post-processing replay RAM estimate ($(to_gb(est.replay_ram_bytes)) GB) is within $(round(Int, 100 * (1 - STORAGE_WARN_FRACTION))) % of storage.max_ram_gb ($(budget.max_ram_gb) GB)."
    end

    max_bytes = budget.max_gb * 1024^3
    if !ret.enabled
        if est.total_bytes > max_bytes
            error(
                "[STORAGE] Estimated storage ($(to_gb(est.total_bytes)) GB) exceeds the configured budget ($(budget.max_gb) GB) and no mitigation is active. Enable [retention], reduce the mission span, or raise storage.max_storage_gb.",
            )
        elseif est.file_count > budget.max_files
            error(
                "[STORAGE] Estimated file count ($(est.file_count)) exceeds storage.max_file_count ($(budget.max_files)) and no mitigation is active. Enable [retention], reduce the mission span, or raise the budget.",
            )
        elseif est.total_bytes > STORAGE_WARN_FRACTION * max_bytes
            @warn "[STORAGE] Estimated storage ($(to_gb(est.total_bytes)) GB) is within $(round(Int, 100 * (1 - STORAGE_WARN_FRACTION))) % of the configured budget ($(budget.max_gb) GB)."
        else
            @info "  -> Status: estimated footprint within budget"
        end
        return nothing
    end

    capped_payload = min(est.prunable_bytes, ret.watermark_bytes)
    steady_bytes = est.total_bytes - est.prunable_bytes + capped_payload
    payload_frac = est.prunable_bytes > 0 ? capped_payload / est.prunable_bytes : 1.0
    steady_files =
        est.file_count - est.prunable_files + ceil(Int, payload_frac * est.prunable_files)

    if steady_bytes > max_bytes
        error(
            "[STORAGE] Even with retention active, the steady-state footprint ($(to_gb(steady_bytes)) GB: non-prunable classes + payload capped at the $(to_gb(ret.watermark_bytes)) GB watermark) exceeds the configured budget ($(budget.max_gb) GB). Reduce the mission span, lower retention.high_watermark_gb, or raise storage.max_storage_gb.",
        )
    elseif steady_files > budget.max_files
        error(
            "[STORAGE] Even with retention active, the steady-state file count ($steady_files) exceeds storage.max_file_count ($(budget.max_files)).",
        )
    end
    if est.total_bytes > max_bytes
        @warn "[STORAGE] Unbounded projection ($(to_gb(est.total_bytes)) GB) exceeds the budget ($(budget.max_gb) GB); retention bounds the steady state to ≈ $(to_gb(steady_bytes)) GB — proceeding."
    end
    grace_sec = ret.grace.value / 1000.0
    grace_payload =
        est.payload_bytes / max(est.n_segments, 1) *
        (grace_sec / Float64(cfg["physics"]["segment_duration_sec"]))
    if grace_payload > ret.watermark_bytes
        @warn "[STORAGE] Payload generated within one retention.grace_hours window (≈ $(to_gb(grace_payload)) GB) exceeds retention.high_watermark_gb ($(to_gb(ret.watermark_bytes)) GB): the custodian cannot honor the grace guarantee and stay below the watermark; the watermark will be exceeded transiently."
    end
    @info "  -> Status: retention active — steady state ≈ $(to_gb(steady_bytes)) GB, ≈ $steady_files files"
    return nothing
end

# --- Improved Simulation Timing ---
"""
    SimulationClock

Tracks the accelerated simulation time mapping real-world wall clock to mission `SimTime`.
"""
struct SimulationClock
    start_real_time::DateTime
    start_sim_time::DateTime
    speed_up::Float64
end

"""
    get_current_sim_time(clock::SimulationClock)

Returns the current accelerated simulation time.
"""
function get_current_sim_time(clock::SimulationClock)
    elapsed_real_ms = (now() - clock.start_real_time).value
    sim_ms = elapsed_real_ms * clock.speed_up
    return clock.start_sim_time + Millisecond(round(Int, sim_ms))
end

"""
    due_wall_time(clock::SimulationClock, sim_time::DateTime) -> DateTime

Wall-clock instant at which the mission clock reaches `sim_time` — the
inverse of [`get_current_sim_time`](@ref). Each due time is computed from
the clock anchor and the absolute mission instant, so pacing loops that
sleep until a due time accumulate no rounding across iterations.
"""
function due_wall_time(clock::SimulationClock, sim_time::DateTime)
    sim_ms = (sim_time - clock.start_sim_time).value
    return clock.start_real_time + Millisecond(round(Int, sim_ms / clock.speed_up))
end

"""
    save_clock_anchor(run_dir::String, clock::SimulationClock, deadline::DateTime)

Persists the mission clock anchor (wall epoch, mission epoch, speed-up) and
the absolute wall-clock deadline into `<run_dir>/clock_anchor.toml`. Written
once at mission start; a re-attaching or restarted component reconstructs
the identical clock from it ([`load_clock_anchor`](@ref)), so mission time
survives component outages — the outage simply elapses as mission time.
"""
function save_clock_anchor(run_dir::String, clock::SimulationClock, deadline::DateTime)
    open(joinpath(run_dir, "clock_anchor.toml"), "w") do io
        TOML.print(
            io,
            Dict(
                "wall_epoch" => string(clock.start_real_time),
                "start_sim_time" => string(clock.start_sim_time),
                "speed_up" => clock.speed_up,
                "deadline_wall" => string(deadline),
            ),
        )
    end
end

"""
    load_clock_anchor(run_dir::String) -> (clock::SimulationClock, deadline::DateTime)

Reconstructs the mission clock and the absolute deadline persisted by
[`save_clock_anchor`](@ref). Errors when the anchor file is absent (runs
started by an older pipeline cannot be re-attached).
"""
function load_clock_anchor(run_dir::String)
    path = joinpath(run_dir, "clock_anchor.toml")
    isfile(path) || error(
        "[RUN] clock_anchor.toml missing in $run_dir — component re-attachment requires the persisted anchor written at mission start.",
    )
    a = TOML.parsefile(path)
    clock = SimulationClock(
        DateTime(a["wall_epoch"]),
        DateTime(a["start_sim_time"]),
        Float64(a["speed_up"]),
    )
    return (clock = clock, deadline = DateTime(a["deadline_wall"]))
end

# --- Data Structures ---
"""
    DataSegment

One contiguous segment of the observed time series: the samples of
`segment_duration_sec` starting at `timestamp`.
"""
struct DataSegment
    id::Int
    timestamp::DateTime
    data::Vector{Float32}
end

"""
    DataBatch

A collection of `DataSegment`s prepared for bulk transmission over the DSN.
"""
struct DataBatch
    id::Int
    segments::Vector{DataSegment}
    created_at::DateTime
end

# --- Metrics Structure for Human Analysis ---
"""
    MissionMetrics

A snapshot of the mission state including queue sizes, effective and nominal
bandwidth, packet-loss counters, and the disruption flag. `bandwidth_pct` is
the *effective* link capacity (visibility × disruption factor);
`nominal_bandwidth_pct` is the visibility profile alone.
"""
struct MissionMetrics
    sim_time::DateTime
    wall_time::DateTime
    hours_elapsed::Float64
    bandwidth_pct::Float64
    onboard_buffer::Int
    link_buffer::Int
    ground_total::Int
    ground_live::Int
    ground_arch::Int
    nominal_bandwidth_pct::Float64
    lost_count::Int
    retry_count::Int
    disruption_active::Bool
end

"""
    save_metrics(run_dir::String, m::MissionMetrics)

Appends a new metrics snapshot to `mission_profile.csv`. The packet-loss and
disruption columns are appended after the legacy columns so pre-loss readers
of old profiles keep working.
"""
function save_metrics(run_dir::String, m::MissionMetrics)
    log_path = joinpath(run_dir, "mission_profile.csv")
    exists = isfile(log_path)

    df = DataFrame(
        SimTime = m.sim_time,
        WallTime = m.wall_time,
        Mission_Day = round(m.hours_elapsed / 24.0, digits = 2),
        Hours_Elapsed = round(m.hours_elapsed, digits = 2),
        Bandwidth_Pct = round(m.bandwidth_pct, digits = 1),
        Onboard_Buffer = m.onboard_buffer,
        Link_Buffer = m.link_buffer,
        Ground_Total = m.ground_total,
        Ground_Live = m.ground_live,
        Ground_Arch = m.ground_arch,
        Nominal_Bandwidth_Pct = round(m.nominal_bandwidth_pct, digits = 1),
        Lost_Count = m.lost_count,
        Retry_Count = m.retry_count,
        Disruption_Active = m.disruption_active,
    )

    # CSV.write in append mode: DrWatson's safesave() has no efficient
    # line-by-line CSV append path.
    CSV.write(log_path, df; append = exists)
end

# --- Ground-Truth Event Logs ---
"""
    log_tx_event(run_dir::String, sim_t::DateTime, batch::String, event::String)

Appends one emitter-side batch milestone to `events_tx.csv`. Events:
`"gen"` (batch finalized onboard), `"tx"` (batch placed on the downlink),
and `"marker"` (`sim_t` = an event-marker instant, `batch` = the batch
holding it; state-preserving).
Together with [`log_rx_event`](@ref) this forms the exact per-batch state
history used by the mask/animation reconstruction — no heuristic replay.
Only the emitter task writes this file (single-writer; no lock needed).
"""
function log_tx_event(run_dir::String, sim_t::DateTime, batch::String, event::String)
    path = joinpath(run_dir, "events_tx.csv")
    df = DataFrame(SimTime = sim_t, Batch = batch, Event = event)
    CSV.write(path, df; append = isfile(path))
end

"""
    log_rx_event(run_dir::String, sim_t::DateTime, batch::String, event::String, attempt::Int)

Appends one receiver-side batch milestone to `events_rx.csv`. Events:
`"ingested"` (batch reached the ground archive), `"retry"` (transfer attempt
lost, batch remains on the link), `"lost"` (retry budget exhausted, batch
moved to `lost/`), and `"pruned"` (retention custodian deleted the delivered
payload CSVs after the grace window; state-preserving for the mask replay).
`attempt` counts failed transfer attempts so far (0 for `"pruned"`).
Only the receiver task writes this file (single-writer; no lock needed).
"""
function log_rx_event(
    run_dir::String,
    sim_t::DateTime,
    batch::String,
    event::String,
    attempt::Int,
)
    path = joinpath(run_dir, "events_rx.csv")
    df = DataFrame(SimTime = sim_t, Batch = batch, Event = event, Attempt = attempt)
    CSV.write(path, df; append = isfile(path))
end

"""
    max_logged_batch_id(run_dir::String) -> Int

Highest batch ID recorded in `events_tx.csv` (0 when the log is absent or
empty) — the authoritative resume point for a re-attaching emitter's batch
counter, immune to batches already delivered out of `onboard/`.
"""
function max_logged_batch_id(run_dir::String)
    path = joinpath(run_dir, "events_tx.csv")
    isfile(path) || return 0
    df = CSV.read(path, DataFrame)
    isempty(df) && return 0
    return maximum(batch_id(String(b)) for b in df.Batch)
end

"""
    backup_existing_dir(path::String) -> Union{String, Nothing}

Directory counterpart of [`backup_existing`](@ref): renames an existing
directory to `<name>#<k>` (smallest unused `k`) so a same-named arrival never
silently overwrites recorded data. Returns the backup path, or `nothing` when
`path` did not exist.
"""
function backup_existing_dir(path::String)
    isdir(path) || return nothing
    k = 1
    while ispath("$(path)#$(k)")
        k += 1
    end
    backup = "$(path)#$(k)"
    mv(path, backup)
    @warn "[SAFESAVE] Existing directory backed up to: $backup"
    return backup
end

# --- Safe File Writing (DrWatson `safesave` semantics for CSV/TOML) ---
"""
    backup_existing(path::String) -> Union{String, Nothing}

If `path` exists, renames it to `<name>#<k><ext>` using the smallest unused
`k`, mirroring DrWatson's `safesave` backup rotation so no result file is ever
silently overwritten. Returns the backup path, or `nothing` if `path` did not
exist. (DrWatson's own `safesave` routes CSVs through FileIO/CSVFiles, which is
not a project dependency, hence this native implementation.)
"""
function backup_existing(path::String)
    isfile(path) || return nothing
    base, ext = splitext(path)
    k = 1
    while isfile("$(base)#$(k)$(ext)")
        k += 1
    end
    backup = "$(base)#$(k)$(ext)"
    mv(path, backup)
    return backup
end

"""
    safe_csv_write(path::String, table) -> String

Writes `table` to `path` as CSV, first rotating any pre-existing file to a
`#k`-suffixed backup via [`backup_existing`](@ref). Returns `path`.
"""
function safe_csv_write(path::String, table)
    backup = backup_existing(path)
    backup !== nothing && @info "[SAFESAVE] Existing file backed up to: $backup"
    CSV.write(path, table)
    return path
end

# --- Run Management ---
"""
    generate_run_id()

Generates a unique ID for the current simulation run,
`RUN_pid=<pid>_t=<yyyymmdd_HHMMSS>` (key=value fields in alphabetical order,
the layout DrWatson's `savename` produced before the dependency was dropped).
"""
function generate_run_id()
    return string("RUN_pid=", getpid(), "_t=", Dates.format(now(), "yyyymmdd_HHMMSS"))
end

"""
    platform_provenance() -> Dict{String,Any}

Hardware and runtime fingerprint stamped into every run's
`config_snapshot.toml` under `[provenance.platform]`: hostname, OS kernel
and architecture, CPU model and logical core count, total memory, Julia
version, thread/BLAS-thread counts, the package version, and the git
commit of the checkout ([`git_commit`](@ref), empty outside a repository).
Together with the configuration snapshot and the recorded input identity,
every result is attributable to config + commit + platform. (No GPU
fields: the pipeline is I/O- and event-loop-bound and uses no GPU
backend.)
"""
function platform_provenance()
    cpu = Sys.cpu_info()
    return Dict{String,Any}(
        "package_version" => string(pkgversion(TelemetryCore)),
        "git_commit" => git_commit(),
        "hostname" => Base.Libc.gethostname(),
        "os" => string(Sys.KERNEL, " ", Sys.MACHINE),
        "cpu_model" => isempty(cpu) ? "unknown" : cpu[1].model,
        "logical_cores" => Sys.CPU_THREADS,
        "total_memory_gb" => round(Sys.total_memory() / 1024^3; digits = 2),
        "julia_version" => string(VERSION),
        "julia_threads" => Threads.nthreads(),
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
    )
end

"""
    git_commit() -> String

The HEAD commit of the package checkout (`git rev-parse HEAD` in the
project root), or `""` when git or the repository is unavailable.
"""
function git_commit()
    try
        return String(
            strip(
                read(
                    pipeline(`git -C $PROJECT_ROOT rev-parse HEAD`; stderr = devnull),
                    String,
                ),
            ),
        )
    catch
        return ""
    end
end

"""
    setup_run_dir(run_id::String; cfg=nothing)

Creates and returns the base directory for a simulation run along with its
required subdirectories. When the parsed configuration `cfg` is provided, a
`config_snapshot.toml` is written into the run directory (with `safesave`-style
backup rotation) so every run's exact parameters remain reproducible after
`config.toml` changes; the snapshot additionally carries the
[`platform_provenance`](@ref) fingerprint under `[provenance.platform]`.
"""
function setup_run_dir(run_id::String; cfg::Union{AbstractDict,Nothing} = nothing)
    base_dir = run_directory(run_id)
    # Run-ID reuse guard (silent-failure mode): a reused ID would interleave
    # two missions' rows in mission_profile.csv and truncate the prior logs.
    if isdir(base_dir) && !isempty(filter(f -> !startswith(f, "."), readdir(base_dir)))
        error(
            "[RUN] Run directory $base_dir already exists and is non-empty — run IDs must be unique. Choose a new run ID or purge the previous run (scripts/maintenance/cleanup.jl).",
        )
    end
    paths = [
        joinpath(base_dir, "onboard"),
        joinpath(base_dir, "link"),
        joinpath(base_dir, "ground"),
        joinpath(base_dir, "lost"),
        joinpath(base_dir, "plots"),
        joinpath(base_dir, "masks"),
    ]
    foreach(mkpath, paths)
    if cfg !== nothing
        # Shallow-copied so the platform stamp never mutates the caller's
        # configuration dictionary.
        snapshot = Dict{String,Any}(cfg)
        prov_in = get(snapshot, "provenance", Dict{String,Any}())
        prov = prov_in isa AbstractDict ? Dict{String,Any}(prov_in) : Dict{String,Any}()
        prov["platform"] = platform_provenance()
        snapshot["provenance"] = prov
        snapshot_path = joinpath(base_dir, "config_snapshot.toml")
        backup_existing(snapshot_path)
        open(snapshot_path, "w") do io
            TOML.print(io, snapshot)
        end
    end
    return base_dir
end

# --- Batch & Segment I/O ---
"""
    save_batch(path::String, batch::DataBatch; markers = String[])

Serializes a `DataBatch` and its metadata to the specified physical directory.
`metadata.json` carries `batch_id`, `segment_count`, `created_at` (mission
time at which the batch was finalized and became transmittable),
`content_epoch` (mission timestamp of the first sample of the payload —
the physical epoch the segment data belong to), and, when given, `markers`
— the labels of the event markers whose instant lies in the payload.
"""
function save_batch(path::String, batch::DataBatch; markers::Vector{String} = String[])
    mkpath(path)
    content_epoch = isempty(batch.segments) ? batch.created_at : batch.segments[1].timestamp
    metadata = Dict{String,Any}(
        "batch_id" => batch.id,
        "segment_count" => length(batch.segments),
        "created_at" => string(batch.created_at),
        "content_epoch" => string(content_epoch),
    )
    isempty(markers) || (metadata["markers"] = markers)
    open(joinpath(path, "metadata.json"), "w") do io
        JSON3.write(io, metadata)
    end

    for seg in batch.segments
        save_segment(joinpath(path, "seg_$(seg.id).csv"), seg)
    end
end

"""
    read_batch_metadata(batch_dir::String) -> Dict{String,Any}

Parses `<batch_dir>/metadata.json`. Returns an empty dictionary when the file
is absent or unparsable (a foreign or truncated directory), so directory
sweeps degrade to "unknown" instead of faulting.
"""
function read_batch_metadata(batch_dir::String)
    path = joinpath(batch_dir, "metadata.json")
    isfile(path) || return Dict{String,Any}()
    parsed = try
        JSON3.read(read(path, String), Dict{String,Any})
    catch e
        @warn "[BATCH] Unparsable metadata.json in $batch_dir — treated as unknown." exception =
            e
        return Dict{String,Any}()
    end
    return parsed
end

"""
    batch_content_epochs(run_dir::String) -> Dict{String,DateTime}

Batch name → content epoch (first-sample mission timestamp) for every batch
directory under `onboard/`, `link/`, `ground/`, and `lost/` whose
`metadata.json` records a `content_epoch` (batches written before that key
existed are omitted).
"""
function batch_content_epochs(run_dir::String)
    epochs = Dict{String,DateTime}()
    for sub in ("onboard", "link", "ground", "lost")
        dir = joinpath(run_dir, sub)
        isdir(dir) || continue
        for name in readdir(dir)
            batch_dir = joinpath(dir, name)
            isdir(batch_dir) || continue
            meta = read_batch_metadata(batch_dir)
            haskey(meta, "content_epoch") || continue
            epoch = tryparse(DateTime, String(meta["content_epoch"]))
            epoch === nothing || (epochs[name] = epoch)
        end
    end
    return epochs
end

"""
    save_segment(path::String, seg::DataSegment)

Saves a 1D `DataSegment` array to a raw CSV format for downstream pipeline usage.
"""
function save_segment(path::String, seg::DataSegment)
    df = DataFrame(Amplitude = seg.data)
    CSV.write(path, df)
end

"""
    load_segment(path::String; timestamp::DateTime = DateTime(0))

Loads a 1D CSV time series back into a `DataSegment`. Segment CSVs persist
only amplitudes, so the mission timestamp cannot be recovered from the file:
callers that know the epoch (e.g. from `metadata.json`'s `created_at`) pass
it via `timestamp`; otherwise the `DateTime(0)` sentinel marks it unknown —
never a fabricated wall-clock time.
"""
function load_segment(path::String; timestamp::DateTime = DateTime(0))
    df = CSV.read(path, DataFrame)
    id_match = match(r"seg_(\d+)\.csv", basename(path))
    # The capture is a Union{Nothing, SubString}: guard the full chain so a
    # nonconforming filename degrades to id 0 instead of throwing.
    id = id_match !== nothing ? something(tryparse(Int, something(id_match[1], "")), 0) : 0
    return DataSegment(id, timestamp, Vector{Float32}(df.Amplitude))
end

# --- Contact windows, visibility & bandwidth ---
"""
    VisibilityModel

Ground-contact model of the downlink. The nominal daily window opens at
`session_start` for `session_duration` with the capacity `profile`
(`sigmoid_steepness`, `gaussian_sigma`); `seasonal_extension` widens it
symmetrically about its centre, cosine-modulated with period
`season_period_days` and peaking at `season_peak_day_of_year`;
`exceptions` (`date => (start, duration)`, zero duration = missed pass)
replace the window of a date verbatim; a non-empty `schedule` of explicit
passes replaces the daily generator altogether; `low_latency` periods are
additional windows at constant capacity outside the nominal passes. The
three- to five-argument constructors build the plain daily model.

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
`progress ∈ [0, 1]` within the window: `sine`, `sigmoid`, `gaussian`, or
`flat` (unknown names fall back to `sine`).
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
        return sin(pi * progress)^2
    end
end

# Composite Simpson subintervals for the profile mean: 10⁻¹⁰ accuracy on the
# shipped profiles at negligible cost (one evaluation per validation and banner).
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

end # module TelemetryCore
