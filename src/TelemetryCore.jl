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
using DataFrames: DataFrames, DataFrame, names
using Dates: Dates, Date, DateTime, Day, Millisecond, Second, Time, now
using JSON: JSON
using InteractiveUtils: InteractiveUtils
using LinearAlgebra: LinearAlgebra
using SHA: SHA, sha256
using TOML: TOML

# --- Constants and run paths ---
"""
    C_LIGHT

Speed of light in vacuum [m s⁻¹].
"""
const C_LIGHT = 2.99792458e8

"""
    PROJECT_ROOT

Absolute path of the package root, anchored at this source file through
`@__DIR__` so that it is stable across precompilation and relocation of the
checkout. Relative configuration paths (`physics.external_data_path`,
`contacts.schedule_csv`, the config file itself) resolve against it.
"""
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

Run-directory path `<DATA_ROOT>/runs/<run_id>`, used alike by the
components, the scripts, and the post-processing tools.
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
# Batch directory names, as used by both components, the replay, and the viewer.

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
    load_config(path::String = "") -> Dict{String,Any}

The parsed TOML configuration at `path`. A relative path resolves against
the current directory first, then the project root; an empty `path` reads
`config.toml` by the same rule. A missing or unparsable file raises a
`[CONFIG]` `ArgumentError`.
"""
function load_config(path::String = "")
    if isempty(path)
        path = isfile("config.toml") ? "config.toml" : joinpath(PROJECT_ROOT, "config.toml")
    elseif !isabspath(path) && !isfile(path)
        # Root fallback, as for contacts.schedule_csv, so that
        # `run_full_sim.jl scenario.toml` works from any directory.
        candidate = joinpath(PROJECT_ROOT, path)
        isfile(candidate) && (path = candidate)
    end
    isfile(path) || config_error("[CONFIG] Configuration file not found at $path")
    try
        return TOML.parsefile(path)
    catch e
        config_error("[CONFIG] Failed to parse $path as TOML: $(sprint(showerror, e))")
    end
end

"""
    csv_header(path::AbstractString) -> Vector{String}

The column names of a CSV file from its first line: split on commas,
surrounding whitespace and double quotes removed. Empty for an empty file.
"""
function csv_header(path::AbstractString)
    line = readline(path)
    isempty(line) && return String[]
    return [String(strip(strip(strip(field), '"'))) for field in split(line, ',')]
end

"""
    load_run_config_with_source(run_dir::String) -> Tuple{Dict{String,Any},String}

The configuration that produced a run, parsed from the run's own
`config_snapshot.toml`, and its source, always `"snapshot"`. The second
value is kept for the `config_source` attribute of the HDF5 export. A
missing or unparsable snapshot raises a `[CONFIG]` `ArgumentError`: the
directory is not a run of this package, and no other configuration stands
in for it.
"""
function load_run_config_with_source(run_dir::String)
    snapshot = joinpath(run_dir, "config_snapshot.toml")
    isfile(snapshot) || config_error(
        "[CONFIG] No config_snapshot.toml in $run_dir: " *
        "not a run directory of this package.",
    )
    parsed = try
        TOML.parsefile(snapshot)
    catch e
        e isa TOML.ParserError || rethrow()
        config_error(
            "[CONFIG] Unparsable config_snapshot.toml in $run_dir: " * sprint(showerror, e),
        )
    end
    return parsed, "snapshot"
end

"""
    load_run_config(run_dir::String)

The configuration that produced a given run: its own `config_snapshot.toml`
and nothing else ([`load_run_config_with_source`](@ref) without the
source). A directory without a parsable snapshot is refused with a
`[CONFIG]` `ArgumentError`. Post-processing must always use this instead of
[`load_config`](@ref), otherwise editing `config.toml` silently
re-parametrizes the analysis of old runs (disruption windows, session
times, physics rates).
"""
load_run_config(run_dir::String) = first(load_run_config_with_source(run_dir))

"""
    mask_timeline_path(run_dir::String) -> String

Path of the batch-state timeline `masks/telemetry_mask_timeline.csv` of a run.
"""
mask_timeline_path(run_dir::String) =
    joinpath(run_dir, "masks", "telemetry_mask_timeline.csv")

"""
    read_mask_timeline(run_dir::String) -> DataFrame

The batch-state timeline of a run as a table, one wide row per event
snapshot. Read on a single task: CSV.jl's multithreaded chunking logs a
failure on that shape before falling back to one task anyway.
"""
read_mask_timeline(run_dir::String) = read_table(mask_timeline_path(run_dir); ntasks = 1)

"""
    mask_timeline_rows(run_dir::String) -> Int

Number of event snapshots in the batch-state timeline: the line count of
the CSV less its header, without parsing the wide rows.
"""
mask_timeline_rows(run_dir::String) = countlines(mask_timeline_path(run_dir)) - 1

# --- Checked config coercions ---
"""
    checked_number(v, name::String) -> Float64

Coerces a config value to `Float64`, aborting with a `[CONFIG]` error naming
the key when the TOML value is not numeric (e.g. a quoted `"3600"`), instead of
surfacing a raw `MethodError` from deep inside the validator or a builder.
"""
function checked_number(v, name::String)
    (v isa Real && !(v isa Bool)) ||
        config_error("[CONFIG] $name must be a number (got $(repr(v))).")
    return Float64(v)
end

"""
    checked_integer(v, name::String) -> Int

Coerces a config value to `Int` with a `[CONFIG]` error naming the key on
non-integer TOML values (strings, floats, booleans).
"""
function checked_integer(v, name::String)
    (v isa Integer && !(v isa Bool)) ||
        config_error("[CONFIG] $name must be an integer (got $(repr(v))).")
    return Int(v)
end

"""
    checked_string(v, name::String) -> String

Coerces a config value to `String` with a `[CONFIG]` error naming the key when
the TOML value is not a string.
"""
function checked_string(v, name::String)
    v isa AbstractString ||
        config_error("[CONFIG] $name must be a string (got $(repr(v))).")
    return String(v)
end

"""
    checked_flag(v, name::String) -> Bool

Coerces a config value to `Bool` with a `[CONFIG]` error naming the key when
the TOML value is not a boolean (e.g. a quoted `"true"`).
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

# --- Configuration schema ---
"""
    STORAGE_CALIBRATION_DEFAULTS

Measured calibration constants of [`estimate_artifacts`](@ref), overridable
key-by-key in `[storage]`: per-artifact disk sizes [bytes], and the RAM of
the replay (`bytes_replay_cell`, per metrics row × batch membership) and of
the figure stage (`bytes_figure_stage`, `bytes_figure_row`). The `[storage]`
schema and the validator iterate this table.
"""
const STORAGE_CALIBRATION_DEFAULTS = (
    bytes_per_sample = 15.0,      # one Float32 CSV value + newline (external series)
    bytes_per_flag_sample = 4.0,  # one 0.0/1.0 CSV value + newline (synthetic flag series)
    bytes_batch_metadata = 96.0,  # metadata.json
    bytes_event_row = 64.0,       # events_tx/rx.csv row
    bytes_metrics_row = 160.0,    # mission_profile.csv row
    bytes_mask_cell = 4.0,        # mask-timeline cell (digit + separator)
    bytes_pointwise_cell = 10.0,  # point-wise expansion row
    bytes_plot = 1.2e6,           # one PNG at px_per_unit = 4 (measured maximum 1.07 MB)
    bytes_plot_pdf = 100_000.0,   # vector PDF twin of one figure
    bytes_replay_cell = 12.0,     # replay RAM per (row x batch) membership
    bytes_figure_stage = 4.5e8,   # figure stage with one figure in memory (measured 3.8e8 above the pre-stage resident size)
    bytes_figure_row = 4500.0,    # plot vertices of the mission summary per metrics row (measured 3850)
    bytes_log_per_batch = 600.0,  # emitter+receiver log lines per batch
)

"""
    FigureProduct

A figure of the post-processing that a `[post_processing]` flag switches:
`flag` (the configuration key, also the stem of the figure file), `default`,
`announcement` (the console line printed before rendering), and `title`
(the subject of the failure record). [`render_figure_product`](@ref) draws
it.
"""
struct FigureProduct
    flag::Symbol
    default::Bool
    announcement::String
    title::String
end

"""
    FIGURE_PRODUCTS

The flagged figure products, in rendering order. The configuration schema,
[`post_processing_settings`](@ref), the artifact estimator, the Supervisor's
post-processing, and the publication export iterate this table, so a new
product is one entry here and one [`render_figure_product`](@ref) method.
"""
const FIGURE_PRODUCTS = (
    FigureProduct(
        :alert_latency,
        true,
        "Computing the alert-latency metric",
        "Alert-latency metric",
    ),
    FigureProduct(
        :delivery_delay,
        true,
        "Computing the delivery-delay metric",
        "Delivery-delay metric",
    ),
    FigureProduct(
        :state_raster,
        true,
        "Rendering the batch-state raster",
        "Batch-state raster",
    ),
)

"""
    render_figure_product(product::Val, run_dir::String, post_processing::NamedTuple, ground::NamedTuple; kwargs...) -> Union{Nothing,String}

Renders the figure product `Val(flag)` of [`FIGURE_PRODUCTS`](@ref) for the
run in `run_dir` and returns the figure path, or `nothing` when the run
holds nothing to draw. `post_processing` and `ground` are the results of
[`post_processing_settings`](@ref) and [`ground_settings`](@ref). The
keywords are those of the plotting functions (`style`, `plots_dir`,
`formats`, `suffix`). The methods live in the modules that own the
figures, `Metrology` and `MissionFigures`.
"""
function render_figure_product end

# Recognized sections and keys; validate_config warns on anything else.
const KNOWN_LABEL_KEYS = ["label", "label_start_index", "label_end_index"]
const KNOWN_CONFIG_KEYS = Dict(
    "simulation" => [
        "mode",
        "speed_up",
        "start_sim_time",
        "mission_wall_seconds",
        "mission_days",
        "initial_downtime_days",
        "rng_seed",
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
        "external_data_columns",
        "sample_rate",
        "segment_duration_sec",
        "batch_size",
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
    "dashboard" => [
        "open_live_viewer",
        "open_receiver_log",
        "open_emitter_log",
        "receiver_status_panel",
    ],
    "post_processing" => vcat(
        [
            "generate_mask_timeline",
            "expand_to_pointwise_masks",
            "target_event_rows",
            "alert_lookback_hours",
            "delivery_requirement_hours",
            "hdf5_export",
            "session_figures",
            "session_figures_max",
            "publication",
        ],
        [String(product.flag) for product in FIGURE_PRODUCTS],
    ),
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
    "payload" => String[], # payload-exporter provenance; free-form by design
    "labels" => KNOWN_LABEL_KEYS,
    "supervision" => ["on_component_failure", "max_restarts", "watchdog_sec"],
)
const FREE_FORM_SECTIONS = ("provenance", "payload")
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

# --- Retired configuration keys ---
# (section, key) => (version of removal, remedy). A live configuration that
# carries one is rejected with the remedy named, not read through a fallback.
const REMOVED_CONFIG_KEYS = Dict(
    ("simulation", "test_duration_sec") =>
        ("1.0.0", "use simulation.mission_wall_seconds"),
    ("simulation", "max_storage_gb") => ("1.0.0", "use storage.max_storage_gb"),
    ("physics", "signal_injection_probability") => ("1.0.0", "use [[events.markers]]"),
    ("post_processing", "generate_batch_matrix") =>
        ("1.0.0", "use post_processing.generate_mask_timeline"),
    ("physics", "confusion_observation_years") => (
        "2.0.0",
        "delete the key: the synthetic payload is the binary flag series of [[events.markers]]",
    ),
    ("physics", "noise_f_min_hz") => (
        "2.0.0",
        "delete the key: the synthetic payload is the binary flag series of [[events.markers]]",
    ),
    ("post_processing", "payload_spectrum") =>
        ("2.0.0", "delete the key: the payload-spectrum figure was removed"),
)

"""
    reject_removed_key(section::AbstractDict, sec_name::String, key::String)

Raises a `[CONFIG]` `ArgumentError` naming the replacement when `section`
still carries `key`, a retired configuration key
(`REMOVED_CONFIG_KEYS`); returns `nothing` otherwise. Called by the
accessors of the affected sections and by [`validate_config`](@ref).
"""
function reject_removed_key(section::AbstractDict, sec_name::String, key::String)
    haskey(section, key) || return nothing
    version, remedy = REMOVED_CONFIG_KEYS[(sec_name, key)]
    config_error("[CONFIG] $sec_name.$key was removed at $version — $remedy.")
end

"""
    reject_removed_section(cfg::AbstractDict)

Raises a `[CONFIG]` `ArgumentError` when the configuration carries the
`[disaster]` section, renamed `[disruption]` before 1.0.0; returns `nothing`
otherwise.
"""
function reject_removed_section(cfg::AbstractDict)
    haskey(cfg, "disaster") && config_error(
        "[CONFIG] The [disaster] section was removed at 1.0.0 — rename it to [disruption].",
    )
    return nothing
end

# --- Configuration accessors ---
"""
    mission_wall_seconds(cfg::AbstractDict) -> Float64

Validated wall-clock mission span `simulation.mission_wall_seconds` (> 0);
the retired alias `simulation.test_duration_sec` is rejected with the
replacement named.

# Examples
```jldoctest
julia> TelemetryCore.mission_wall_seconds(Dict{String,Any}("simulation" => Dict{String,Any}("mission_wall_seconds" => 168.0)))
168.0
```
"""
function mission_wall_seconds(cfg::AbstractDict)
    sim = get(cfg, "simulation", Dict{String,Any}())
    reject_removed_key(sim, "simulation", "test_duration_sec")
    raw = get(sim, "mission_wall_seconds", nothing)
    raw === nothing &&
        config_error("[CONFIG] Missing required key simulation.mission_wall_seconds.")
    v = checked_number(raw, "simulation.mission_wall_seconds")
    v > 0.0 ||
        config_error("[CONFIG] simulation.mission_wall_seconds must be > 0 (got $v).")
    return v
end

"""
    SIMULATION_MODES

The values of `simulation.mode`: `"wall"`, the operational mode paced
against the wall clock at `speed_up` for `mission_wall_seconds`
([`SimulationClock`](@ref)), and `"tick"`, the analysis mode on the logical
clock of [`TickClock`](@ref) spanning `mission_days`.
"""
const SIMULATION_MODES = ("wall", "tick")

"""
    simulation_mode(cfg::AbstractDict) -> String

Validated `simulation.mode`, one of [`SIMULATION_MODES`](@ref); `"wall"`
when absent.

# Examples
```jldoctest
julia> TelemetryCore.simulation_mode(Dict{String,Any}())
"wall"
```
"""
function simulation_mode(cfg::AbstractDict)
    sim = get(cfg, "simulation", Dict{String,Any}())
    mode = lowercase(checked_string(get(sim, "mode", "wall"), "simulation.mode"))
    mode in SIMULATION_MODES || config_error(
        "[CONFIG] simulation.mode must be one of \"wall\" | \"tick\" (got \"$mode\").",
    )
    return mode
end

"""
    mission_days_setting(cfg::AbstractDict) -> Float64

Validated `simulation.mission_days` (> 0), the span of a mission in
`simulation.mode = "tick"`; missing is a configuration error naming the
mode.
"""
function mission_days_setting(cfg::AbstractDict)
    sim = get(cfg, "simulation", Dict{String,Any}())
    raw = get(sim, "mission_days", nothing)
    raw === nothing && config_error(
        "[CONFIG] Missing required key simulation.mission_days (simulation.mode = \"tick\" spans mission_days of logical time).",
    )
    v = checked_number(raw, "simulation.mission_days")
    v > 0.0 || config_error("[CONFIG] simulation.mission_days must be > 0 (got $v).")
    return v
end

"""
    tick_configuration(cfg::AbstractDict) -> Dict{String,Any}

A copy of a configuration switched to `simulation.mode = "tick"` with the
same mission span: `mission_days` set from [`mission_span_days`](@ref),
`speed_up` and `mission_wall_seconds` removed, and the console status
panel off. A wall scenario runs deterministically through it; a
configuration already in tick mode comes back unchanged. The result is
validated like any other configuration when it is run.

# Examples
```jldoctest
julia> cfg = Dict{String,Any}("simulation" => Dict{String,Any}("speed_up" => 3600.0, "mission_wall_seconds" => 168.0, "start_sim_time" => "2035-01-01T06:00:00"));

julia> sim = TelemetryCore.tick_configuration(cfg)["simulation"];

julia> sim["mode"], sim["mission_days"], haskey(sim, "speed_up")
("tick", 7.0, false)
```
"""
function tick_configuration(cfg::AbstractDict)
    out = deepcopy(Dict{String,Any}(cfg))
    simulation_mode(out) == "tick" && return out
    days = mission_span_days(out)
    sim = out["simulation"]
    delete!(sim, "speed_up")
    delete!(sim, "mission_wall_seconds")
    sim["mode"] = "tick"
    sim["mission_days"] = days
    if haskey(out, "dashboard") && out["dashboard"] isa AbstractDict
        out["dashboard"]["receiver_status_panel"] = false
    end
    return out
end

"""
    mission_span_days(cfg::AbstractDict) -> Float64

The mission span in days in either mode: `mission_wall_seconds × speed_up /
86 400` in wall mode, `mission_days` in tick mode.
"""
function mission_span_days(cfg::AbstractDict)
    simulation_mode(cfg) == "tick" && return mission_days_setting(cfg)
    sim = get(cfg, "simulation", Dict{String,Any}())
    speed_up =
        checked_number(required_value(sim, "simulation", "speed_up"), "simulation.speed_up")
    return mission_wall_seconds(cfg) * speed_up / 86_400.0
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

# Section accessors: every consumer, the validator included, reads a section
# through one of these, so each bound and default is defined once.

"""
    telemetry_settings(cfg::AbstractDict) -> NamedTuple

Validated `[telemetry]` parameters: `session_start::Time`,
`session_duration::Second` (`session_duration_hours ∈ (0, 24]`: the daily
scheduler wraps `Time` arithmetic at 24 h), `bandwidth_profile::String` (one
of [`BANDWIDTH_PROFILES`](@ref)), `sigmoid_steepness`, `gaussian_sigma`,
`max_batches_per_hour`, `max_inflight_batches::Int`, `min_link_factor`, and
`range_million_km ≥ 0` (spacecraft–Earth range; `0` disables the light-time
delay) with the derived `round_trip_light_time_sec = 2 · range / c`.

The link capacity is given either as `max_batches_per_hour` or as the rate
pair `downlink_kbps` and `onboard_data_rate_kbps` (both > 0); the two forms
are mutually exclusive, and the pair fixes the capacity in batches per hour
through the batch content span of `[physics]`. `nominal_batch_transfer_sec`
is the transfer time of one batch at full capacity; `catch_up_ratio`
(downlink over production rate) and `onboard_data_rate_kbps` are `NaN` in
the batches-per-hour form.

Bounds raise `[CONFIG]` errors. Absent keys take their defaults, so the
snapshot of an older run still reads; [`validate_config`](@ref) applies the
required-key policy of a live configuration.

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
    bandwidth_profile in BANDWIDTH_PROFILES || config_error(
        "[CONFIG] Unknown telemetry.bandwidth_profile = \"$bandwidth_profile\" (expected one of $(join(repr.(BANDWIDTH_PROFILES), ", "))).",
    )
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
malformed-but-disabled section fails fast instead of surfacing only once
the channel is enabled.
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
    is_whole_milliseconds(seconds::Real) -> Bool

Whether `seconds` is a whole number of milliseconds, at least one, to within
the rounding of a decimal literal (`0.07 * 1000` is not exactly `70`). The
content clock is a `DateTime`, which resolves milliseconds.
"""
function is_whole_milliseconds(seconds::Real)
    ms = 1000 * seconds
    return ms >= 1 && isapprox(ms, round(ms); atol = 1e-6)
end

"""
    segment_period(segment_duration_sec::Real) -> Millisecond

Content span of one segment on the mission clock. `ArgumentError` unless the
duration is a whole number of milliseconds ([`is_whole_milliseconds`](@ref)).
"""
function segment_period(segment_duration_sec::Real)
    is_whole_milliseconds(segment_duration_sec) || throw(
        ArgumentError(
            "segment_duration_sec must be a whole number of milliseconds (got $segment_duration_sec).",
        ),
    )
    return Millisecond(round(Int, 1000 * segment_duration_sec))
end

"""
    physics_settings(cfg::AbstractDict) -> NamedTuple

Validated `[physics]` parameters: `data_source` (`"synthetic"` or
`"external"`), `external_data_path` (as configured; consumers resolve it
against the package root), `external_data_columns`, `sample_rate > 0`,
`segment_duration_sec > 0` and a whole number of milliseconds (the
resolution of the content clock), and `batch_size ≥ 1`, with at least one
sample per segment. The four core keys are required.

`external_data_columns` lists unique, non-empty column names of the
external file, ingested in that order, and is rejected with the synthetic
source; left empty, the `Amplitude` column is ingested, or else the first
column, under the name `Amplitude`.

The retired `signal_injection_probability` is rejected (event instants are
`[[events.markers]]`). The keys retired at 2.0.0 and the existence of the
external file are checked by [`validate_config`](@ref) only, so that
post-processing of a finished run reads its snapshot even after a key was
retired or the input file removed.
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
    is_whole_milliseconds(segment_duration) || config_error(
        "[CONFIG] physics.segment_duration_sec must be a whole number of milliseconds (got $segment_duration).",
    )
    batch_size =
        checked_integer(required_value(phy, "physics", "batch_size"), "physics.batch_size")
    batch_size >= 1 ||
        config_error("[CONFIG] physics.batch_size must be ≥ 1 (got $batch_size).")
    n_samples = sample_rate * segment_duration
    n_samples >= 1.0 || config_error(
        "[CONFIG] sample_rate × segment_duration_sec = $n_samples < 1: a segment must hold at least one sample.",
    )
    data_source =
        checked_string(required_value(phy, "physics", "data_source"), "physics.data_source")
    data_source in ("synthetic", "external") || config_error(
        "[CONFIG] Unknown physics.data_source = \"$data_source\" (expected \"synthetic\" or \"external\").",
    )
    external_data_path =
        checked_string(get(phy, "external_data_path", ""), "physics.external_data_path")
    raw_columns = get(phy, "external_data_columns", Any[])
    raw_columns isa AbstractVector || config_error(
        "[CONFIG] physics.external_data_columns must be a list of column names.",
    )
    external_data_columns = String[]
    for (i, value) in enumerate(raw_columns)
        column = checked_string(value, "physics.external_data_columns[$i]")
        isempty(column) &&
            config_error("[CONFIG] physics.external_data_columns[$i] must not be empty.")
        push!(external_data_columns, column)
    end
    allunique(external_data_columns) || config_error(
        "[CONFIG] physics.external_data_columns must be unique (got $external_data_columns).",
    )
    data_source == "synthetic" &&
        !isempty(external_data_columns) &&
        config_error(
            "[CONFIG] physics.external_data_columns applies to data_source = \"external\" only.",
        )
    reject_removed_key(phy, "physics", "signal_injection_probability")
    return (
        data_source = data_source,
        external_data_path = external_data_path,
        external_data_columns = external_data_columns,
        sample_rate = sample_rate,
        segment_duration_sec = segment_duration,
        batch_size = batch_size,
    )
end

"""
    EventMarker

One `[[events.markers]]` entry: the mission instant `time` of an event of
interest (a transient, a glitch), its `label`, and an optional triggered
low-latency period — `low_latency_after_hours` after the marker, lasting
`low_latency_duration_hours` (`0` = none) at `low_latency_capacity_fraction`
of peak capacity (`NaN` = the `[contacts]` default). `EventMarker(time,
label)` builds a marker without a triggered period.
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
    LabelSpan

A labeled span of payload rows declared by the scenario (`[[labels]]`):
its `label` and the inclusive payload rows `row_first … row_last`. A span
with `row_first > row_last` is empty (an event without labeled samples)
and is dropped from the label-span table.
"""
struct LabelSpan
    label::String
    row_first::Int
    row_last::Int
end

"""
    label_settings(cfg::AbstractDict) -> Vector{LabelSpan}

Validated `[[labels]]` entries in file order: `label` (default
`label <i>`), `label_start_index` and `label_end_index` (integers ≥ 1,
both required). A malformed entry raises a `[CONFIG]` error.
"""
function label_settings(cfg::AbstractDict)
    spans = LabelSpan[]
    for (i, e) in enumerate(get(cfg, "labels", Any[]))
        e isa AbstractDict ||
            config_error("[CONFIG] labels[$i] must be a table of label keys.")
        label = checked_string(get(e, "label", "label $i"), "labels[$i].label")
        rows = Int[]
        for key in ("label_start_index", "label_end_index")
            haskey(e, key) || config_error("[CONFIG] labels[$i].$key is required.")
            v = checked_integer(e[key], "labels[$i].$key")
            v >= 1 || config_error("[CONFIG] labels[$i].$key must be ≥ 1 (got $v).")
            push!(rows, v)
        end
        push!(spans, LabelSpan(label, rows[1], rows[2]))
    end
    return spans
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
`format` (`"pdf"` | `"svg"`, default `"pdf"`), `column_width_mm ∈ [100, 400]`
(default 178; the standard layout is scaled as a whole to this printed
width, `PlotTheme.style_for_width`), and `export_dir` (default `""` =
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
            @warn "[CONFIG] Unrecognized key post_processing.publication.$key — ignored."
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
    100.0 <= width <= 400.0 || config_error(
        "[CONFIG] post_processing.publication.column_width_mm must lie in [100, 400] (got $width).",
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
    post_processing_settings(cfg::AbstractDict) -> NamedTuple

Validated `[post_processing]` section: `generate_mask_timeline` (default
`true`), `expand_to_pointwise_masks` (`false`), `target_event_rows`
([`normalize_target_rows`](@ref), default `[-1]`), `alert_lookback_hours > 0`
(72), `delivery_requirement_hours > 0` (24), `hdf5_export` (`false`),
`session_figures` (`true`, the per-contact session figures),
`session_figures_max ≥ 0` (0; the cap on their number, 0 for no cap), and
`figures`, a `NamedTuple` of booleans keyed by the flags of
[`FIGURE_PRODUCTS`](@ref) with their defaults. The retired
`generate_batch_matrix` is rejected with its replacement named;
`[post_processing.publication]` is read by [`publication_settings`](@ref).

# Examples
```jldoctest
julia> pp = TelemetryCore.post_processing_settings(Dict{String,Any}());

julia> pp.generate_mask_timeline, pp.hdf5_export, pp.alert_lookback_hours
(true, false, 72.0)

julia> pp.figures
(alert_latency = true, delivery_delay = true, state_raster = true)
```
"""
function post_processing_settings(cfg::AbstractDict)
    pp = get(cfg, "post_processing", Dict{String,Any}())
    reject_removed_key(pp, "post_processing", "generate_batch_matrix")
    flag(key, default) = checked_flag(get(pp, key, default), "post_processing.$key")
    function positive(key, default)
        v = checked_number(get(pp, key, default), "post_processing.$key")
        v > 0.0 || config_error("[CONFIG] post_processing.$key must be > 0 (got $v).")
        return v
    end
    flags = map(product -> product.flag, FIGURE_PRODUCTS)
    session_figures_max = checked_integer(
        get(pp, "session_figures_max", 0),
        "post_processing.session_figures_max",
    )
    session_figures_max >= 0 || config_error(
        "[CONFIG] post_processing.session_figures_max must be >= 0 (got $session_figures_max).",
    )
    return (
        generate_mask_timeline = flag("generate_mask_timeline", true),
        expand_to_pointwise_masks = flag("expand_to_pointwise_masks", false),
        target_event_rows = normalize_target_rows(get(pp, "target_event_rows", [-1])),
        alert_lookback_hours = positive("alert_lookback_hours", 72.0),
        delivery_requirement_hours = positive("delivery_requirement_hours", 24.0),
        hdf5_export = flag("hdf5_export", false),
        session_figures = flag("session_figures", true),
        session_figures_max = session_figures_max,
        figures = NamedTuple{flags}(
            map(product -> flag(String(product.flag), product.default), FIGURE_PRODUCTS),
        ),
    )
end

"""
    dashboard_settings(cfg::AbstractDict) -> NamedTuple

Validated `[dashboard]` flags, each a boolean: `open_live_viewer`,
`open_receiver_log`, and `open_emitter_log` (the terminals the dashboard
launcher opens; default `true`) and `receiver_status_panel` (the receiver's
in-console status panel; default `false`). A non-boolean value is rejected
with a `[CONFIG]` error.

# Examples
```jldoctest
julia> TelemetryCore.dashboard_settings(Dict{String,Any}()).receiver_status_panel
false
```
"""
function dashboard_settings(cfg::AbstractDict)
    db = get(cfg, "dashboard", Dict{String,Any}())
    flag(key, default) = checked_flag(get(db, key, default), "dashboard.$key")
    return (
        open_live_viewer = flag("open_live_viewer", true),
        open_receiver_log = flag("open_receiver_log", true),
        open_emitter_log = flag("open_emitter_log", true),
        receiver_status_panel = flag("receiver_status_panel", false),
    )
end

# --- Payload grid ---
"""
    payload_row_time(origin::DateTime, sample_rate::Real, row::Integer) -> DateTime

The mission instant of payload row `row`: `origin + (row − 1) / sample_rate`
on the millisecond grid.
"""
payload_row_time(origin::DateTime, sample_rate::Real, row::Integer) =
    origin + Millisecond(round(Int, 1000 * (row - 1) / sample_rate))

"""
    payload_time_row(origin::DateTime, sample_rate::Real, t::DateTime) -> Int

The payload row at the mission instant `t`, the inverse of
[`payload_row_time`](@ref).
"""
payload_time_row(origin::DateTime, sample_rate::Real, t::DateTime) =
    round(Int, Dates.value(t - origin) * sample_rate / 1000) + 1

"""
    mission_epoch(cfg::AbstractDict) -> DateTime

The mission epoch `simulation.start_sim_time` of a configuration.
"""
mission_epoch(cfg::AbstractDict) = parsed_datetime(
    required_value(
        get(cfg, "simulation", Dict{String,Any}()),
        "simulation",
        "start_sim_time",
    ),
    "simulation.start_sim_time",
)

"""
    mission_end(cfg::AbstractDict) -> DateTime

The nominal end of the mission, `mission_epoch(cfg)` plus
[`mission_span_days`](@ref) rounded to the millisecond; the gap table closes
a generation gap still open at the end of the run at this instant.
"""
mission_end(cfg::AbstractDict) =
    mission_epoch(cfg) + Millisecond(round(Int, mission_span_days(cfg) * MS_PER_DAY))

"""
    payload_origin(cfg::AbstractDict) -> DateTime

The content instant of payload row 1: `provenance.payload_origin` of a run
snapshot when present, otherwise `mission_epoch(cfg)` less
`simulation.initial_downtime_days` (clamped at zero days), the rule of
`Emitter.instrument_epoch`.
"""
function payload_origin(cfg::AbstractDict)
    provenance = get(cfg, "provenance", Dict{String,Any}())
    haskey(provenance, "payload_origin") && return DateTime(provenance["payload_origin"])
    sim = get(cfg, "simulation", Dict{String,Any}())
    downtime = Float64(get(sim, "initial_downtime_days", 0.0))
    return mission_epoch(cfg) - Millisecond(max(0, round(Int, downtime * MS_PER_DAY)))
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
    save_markers(run_dir::String, markers::Vector{EventMarker};
                 origin = nothing, sample_rate = 0.0)

Writes `<run_dir>/markers.csv` (`SimTime, Label, PayloadRow`) — the run's
event instants for consumers and post-processing; `PayloadRow`, the payload
row of the marker's instant, is written when `origin` is given and
`sample_rate > 0`. Nothing is written when there are no markers.
"""
function save_markers(
    run_dir::String,
    markers::Vector{EventMarker};
    origin::Union{DateTime,Nothing} = nothing,
    sample_rate::Real = 0.0,
)
    isempty(markers) && return nothing
    df = DataFrame(SimTime = [m.time for m in markers], Label = [m.label for m in markers])
    if origin !== nothing && sample_rate > 0
        df.PayloadRow = [payload_time_row(origin, sample_rate, m.time) for m in markers]
    end
    safe_csv_write(joinpath(run_dir, "markers.csv"), df)
    return nothing
end

"""
    DESCRIPTOR_PRODUCTS

The tabular products [`write_run_descriptor`](@ref) lists with their size
and SHA-256, those present in the run directory.
"""
const DESCRIPTOR_PRODUCTS = (
    "events_tx.csv",
    "events_rx.csv",
    "holes.csv",
    "mission_profile.csv",
    "markers.csv",
    "label_spans.csv",
    "component_events.csv",
    "delivery_delay.csv",
    "alert_latency.csv",
    "alert_latency_markers.csv",
    "masks/gaps.csv",
    "masks/batch_epochs.csv",
    "masks/telemetry_mask_timeline.csv",
)

"""
    write_run_descriptor(run_dir::String) -> String

Writes `<run_dir>/descriptor.toml`, the run's identity for a downstream
collection to copy verbatim, and returns its path. Fields: `schema`,
`run_id`, the producer's `package_version` and source identity
(`identity_source`, `git_commit`, `git_tree_sha1`, `git_dirty`, `repo_url`,
`repo_rev`; [`source_identity`](@ref)), `config_sha256`, the clock `mode`,
`mission_days`, `start_sim_time`, `payload_origin`, `rng_seed`, the payload
geometry (`sample_rate`, `segment_duration_sec`, `batch_size`,
`points_per_batch`), `payload_columns` (those stamped into the provenance
of an external run, else `["Amplitude"]`), `external_data_sha256` and
`external_data_rows` when recorded, `written_at`, and under `[products]`
the size and SHA-256 of every table of [`DESCRIPTOR_PRODUCTS`](@ref)
present. The source-identity fields added in 2.6.1 are empty for an
earlier run.

Written last among the post-processing products, so the hashes are final;
an existing descriptor is rotated ([`backup_existing`](@ref)).
"""
function write_run_descriptor(run_dir::String)
    cfg = load_run_config(run_dir)
    sim = get(cfg, "simulation", Dict{String,Any}())
    provenance = get(cfg, "provenance", Dict{String,Any}())
    platform = get(provenance, "platform", Dict{String,Any}())
    physics = physics_settings(cfg)
    descriptor = Dict{String,Any}(
        "schema" => "deepspacetelemetry-run/1",
        "run_id" => basename(run_dir),
        "package_version" => String(get(platform, "package_version", "")),
        "identity_source" => String(get(platform, "identity_source", "")),
        "git_commit" => String(get(platform, "git_commit", "")),
        "git_tree_sha1" => String(get(platform, "git_tree_sha1", "")),
        "git_dirty" => Bool(get(platform, "git_dirty", false)),
        "repo_url" => String(get(platform, "repo_url", "")),
        "repo_rev" => String(get(platform, "repo_rev", "")),
        "config_sha256" => String(get(provenance, "config_sha256", "")),
        "mode" => simulation_mode(cfg),
        "mission_days" => mission_span_days(cfg),
        "start_sim_time" => string(get(sim, "start_sim_time", "")),
        "payload_origin" => string(get(provenance, "payload_origin", "")),
        "rng_seed" => Int(get(sim, "rng_seed", 0)),
        "sample_rate" => physics.sample_rate,
        "segment_duration_sec" => physics.segment_duration_sec,
        "batch_size" => physics.batch_size,
        "points_per_batch" =>
            round(Int, physics.sample_rate * physics.segment_duration_sec) *
            physics.batch_size,
        "written_at" => string(now()),
    )
    for key in ("external_data_sha256", "external_data_rows")
        haskey(provenance, key) && (descriptor[key] = provenance[key])
    end
    columns =
        physics.data_source == "external" ?
        Vector{String}(get(provenance, "external_data_columns", [PAYLOAD_COLUMN_DEFAULT])) :
        [PAYLOAD_COLUMN_DEFAULT]
    descriptor["payload_columns"] = columns
    products = Dict{String,Any}()
    for rel in DESCRIPTOR_PRODUCTS
        path = joinpath(run_dir, split(rel, '/')...)
        isfile(path) || continue
        products[rel] = Dict{String,Any}(
            "bytes" => filesize(path),
            "sha256" => bytes2hex(open(sha256, path)),
        )
    end
    descriptor["products"] = products
    path = joinpath(run_dir, "descriptor.toml")
    backup_existing(path)
    open(path, "w") do io
        TOML.print(io, descriptor)
    end
    return path
end

"""
    load_markers(run_dir::String) -> Vector{EventMarker}

The markers recorded in `<run_dir>/markers.csv` (empty when absent), as
plain [`EventMarker`](@ref)s without triggered periods.
"""
function load_markers(run_dir::String)
    path = joinpath(run_dir, "markers.csv")
    isfile(path) || return EventMarker[]
    df = read_table(path)
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

Validated `[[disruption.events]]` entries in file order (the pre-1.0
`[[disaster.events]]` section name is rejected): `type`, `label`,
`start_day ≥ 0` (required), `duration_hours > 0`, `recovery_hours ≥ 0`,
`severity ∈ [0, 1]`, `loss_multiplier`, and `affects` — `"link"` (the
default: a capacity and loss disruption) or `"generation"` (a scheduled
gap in data production of `duration_hours`; severity, recovery, and loss
keys are ignored). `type = "antenna_repointing"` defaults to
`"generation"`. A malformed event raises an error rather than being
skipped: a silently missing disruption invalidates the scenario.
"""
function disruption_event_settings(cfg::AbstractDict)
    reject_removed_section(cfg)
    d = get(cfg, "disruption", Dict{String,Any}())
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

The on-board recorder ceiling from `storage.onboard_capacity_days > 0`:
`days`; `batches`, the production over that span in whole batches (at least
one), which the emitter enforces; and `gigabit`, the physical volume when
the link is given as a rate pair, else `NaN`. The default of 14 days is the
autonomy without ground contact of the Definition Study Report (Colpi et al.
2024, [doi:10.48550/arXiv.2402.07571](https://doi.org/10.48550/arXiv.2402.07571)).
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
    open_recorder_gap_start(run_dir::String) -> Union{DateTime,Nothing}

The `SimTime` of the `RECORDER` `gap_start` row of `events_tx.csv` not yet
matched by a `gap_end`, `nothing` when no recorder gap is open: a
re-entering emitter closes that gap at its first finalization that finds
room, and the declared-hole feed needs the start to declare it.
"""
function open_recorder_gap_start(run_dir::String)
    path = joinpath(run_dir, "events_tx.csv")
    isfile(path) || return nothing
    df = read_table(path)
    isempty(df) && return nothing
    start::Union{DateTime,Nothing} = nothing
    for r in eachrow(df)
        String(r.Batch) == "RECORDER" || continue
        if r.Event == "gap_start"
            start = DateTime(r.SimTime)
        elseif r.Event == "gap_end"
            start = nothing
        end
    end
    return start
end

"""
    open_recorder_gap(run_dir::String) -> Bool

Whether the last recorder-overflow gap in `events_tx.csv` (rows with
Batch = `RECORDER`) is still open — a `gap_start` without its `gap_end` —
so a re-attaching emitter closes it when the buffer has room again.
"""
open_recorder_gap(run_dir::String) = open_recorder_gap_start(run_dir) !== nothing

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

"""
    hours_period(hours::Float64) -> Millisecond

The `Millisecond` period of a duration given in hours, rounded to the
millisecond (contact-window and low-latency-period lengths).
"""
hours_period(hours::Float64) = Millisecond(round(Int, MS_PER_HOUR * hours))

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
    ([`event_marker_settings`](@ref)) are appended, labeled by the marker.

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
        header = strip.(split(readline(path), ','))
        df =
            "Start" in header ?
            CSV.read(path, DataFrame; types = Dict(:Start => String), stringtype = String) :
            CSV.read(path, DataFrame; stringtype = String)
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

Validates a live configuration before any directory is created or any
computation starts, and returns `cfg`; the safe interval of every key is
documented inline in `config.toml`. A value that would break the pipeline
raises a `[CONFIG]` `ArgumentError`; a runnable but suspicious one emits a
`@warn`.

Errors:
  - a missing required key: `simulation.start_sim_time` (and `speed_up` in
    wall mode), `telemetry.session_start` and `session_duration_hours`, the
    four core `[physics]` keys, and a link capacity
  - a span key of the other clock mode, and
    `dashboard.receiver_status_panel = true` in tick mode
  - every type, bound, and enumeration enforced by the accessors it calls:
    [`simulation_mode`](@ref), [`mission_wall_seconds`](@ref),
    [`mission_days_setting`](@ref), [`telemetry_settings`](@ref),
    [`physics_settings`](@ref), [`loss_channel_settings`](@ref),
    [`disruption_event_settings`](@ref), [`contacts_settings`](@ref)
    (with [`event_marker_settings`](@ref)), [`label_settings`](@ref),
    [`ground_settings`](@ref), [`publication_settings`](@ref),
    [`post_processing_settings`](@ref), [`dashboard_settings`](@ref),
    [`supervision_settings`](@ref), and [`onboard_capacity`](@ref)
  - a non-positive `speed_up` or `[storage]` value, a negative
    `initial_downtime_days`, a non-integer `rng_seed`, a non-boolean
    `retention.enabled` or non-positive `[retention]` value, and a
    `retention.high_watermark_gb` above the storage budget
  - `data_source = "external"` with a missing file or with an
    `external_data_columns` entry absent from its header
  - the retired keys of `REMOVED_CONFIG_KEYS` and the `[disaster]` section,
    rejected with the replacement named

Warnings:
  - in wall mode, an emitter period `segment_duration_sec / speed_up` below
    [`EMITTER_PERIOD_WARN_MS`](@ref) (the generation loop cannot keep pace)
    or a receiver download slot `nominal_batch_transfer_sec / speed_up`
    below [`RECEIVER_SLOT_WARN_MS`](@ref) (the
    [`RECEIVER_SLEEP_FLOOR_SEC`](@ref) sleep floor distorts the download rate)
  - the rate pair with a shaped `bandwidth_profile` (the profile mean scales
    a rate the pass sustains; the warning states the capacity of one nominal
    pass against the daily production)
  - a non-integer `sample_rate × segment_duration_sec` (rounded)
  - `initial_downtime_days`, or the longest interval without ground
    contact, beyond the on-board recorder capacity
  - with packet loss enabled, Gilbert–Elliott `p_bad_to_good = 0` (the
    channel never recovers), and loss saturation: the worst-state
    per-attempt loss times the largest `loss_multiplier` reaches 1, so every
    transfer fails in that regime
  - disruption events that start at or after mission end (they never
    fire), black out the link to mission end, or have their blackout +
    recovery tail truncated by it; overlapping events (capacity composes as
    the minimum, the loss multiplier as the maximum); `loss_multiplier < 1`
  - `post_processing.state_raster` with `generate_mask_timeline` disabled
    (the raster is drawn from the mask timeline and is skipped)
  - unrecognized sections and keys, which would otherwise fall back to
    their defaults unnoticed
"""
function validate_config(cfg::AbstractDict)
    # Retired keys first, so that the typo sweep below sees only live keys.
    reject_removed_section(cfg)
    for (section, key) in keys(REMOVED_CONFIG_KEYS)
        content = get(cfg, section, nothing)
        content isa AbstractDict && reject_removed_key(content, section, key)
    end
    # Unrecognized-key sweep.
    for (section, content) in cfg
        if !haskey(KNOWN_CONFIG_KEYS, section)
            @warn "[CONFIG] Unrecognized section [$section] — its keys are ignored."
        elseif !(section in FREE_FORM_SECTIONS) && content isa AbstractDict
            for key in keys(content)
                key in KNOWN_CONFIG_KEYS[section] ||
                    @warn "[CONFIG] Unrecognized key $section.$key — ignored."
            end
        end
    end
    for (i, e) in
        enumerate(get(get(cfg, "disruption", Dict{String,Any}()), "events", Any[]))
        e isa AbstractDict || continue
        for key in keys(e)
            key in KNOWN_EVENT_KEYS ||
                @warn "[CONFIG] Unrecognized key disruption.events[$i].$key — ignored."
        end
    end
    for (i, e) in enumerate(get(get(cfg, "events", Dict{String,Any}()), "markers", Any[]))
        e isa AbstractDict || continue
        for key in keys(e)
            key in KNOWN_MARKER_KEYS ||
                @warn "[CONFIG] Unrecognized key events.markers[$i].$key — ignored."
        end
    end
    for (i, e) in enumerate(get(cfg, "labels", Any[]))
        e isa AbstractDict || continue
        for key in keys(e)
            key in KNOWN_LABEL_KEYS ||
                @warn "[CONFIG] Unrecognized key labels[$i].$key — ignored."
        end
    end
    contacts_section = get(cfg, "contacts", Dict{String,Any}())
    for (list, known) in KNOWN_CONTACT_ENTRY_KEYS
        for (i, e) in enumerate(get(contacts_section, list, Any[]))
            e isa AbstractDict || continue
            for key in keys(e)
                key in known ||
                    @warn "[CONFIG] Unrecognized key contacts.$list[$i].$key — ignored."
            end
        end
    end

    sim = get(cfg, "simulation", Dict{String,Any}())
    tel = get(cfg, "telemetry", Dict{String,Any}())
    phy = get(cfg, "physics", Dict{String,Any}())

    # Required keys: a missing core tunable is a configuration error, never
    # a silently invented default.
    mode = simulation_mode(cfg)
    for (section, sec_name, required) in (
        (
            sim,
            "simulation",
            mode == "tick" ? ("start_sim_time",) : ("speed_up", "start_sim_time"),
        ),
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
    # A span key of the other mode is an error, not a value silently ignored.
    speed_up = NaN # wall mode only; read below by the pacing warnings
    if mode == "tick"
        for key in ("speed_up", "mission_wall_seconds")
            haskey(sim, key) && config_error(
                "[CONFIG] simulation.$key has no meaning in simulation.mode = \"tick\": the mission spans simulation.mission_days of logical time; remove it.",
            )
        end
        mission_days_setting(cfg)
        dashboard_settings(cfg).receiver_status_panel && config_error(
            "[CONFIG] dashboard.receiver_status_panel needs the wall clock: set it false in simulation.mode = \"tick\".",
        )
    else
        haskey(sim, "mission_days") && config_error(
            "[CONFIG] simulation.mission_days is read in simulation.mode = \"tick\" only: in wall mode the span is mission_wall_seconds × speed_up; remove it.",
        )
        speed_up = checked_number(get(sim, "speed_up", 0.0), "simulation.speed_up")
        speed_up > 0.0 ||
            config_error("[CONFIG] simulation.speed_up must be > 0 (got $speed_up).")
        mission_wall_seconds(cfg)
    end
    mission_days = mission_span_days(cfg)
    downtime = checked_number(
        get(sim, "initial_downtime_days", 0.0),
        "simulation.initial_downtime_days",
    )
    downtime >= 0.0 || config_error(
        "[CONFIG] simulation.initial_downtime_days must be ≥ 0 (got $downtime).",
    )
    max_gb = storage_budget(cfg).max_gb
    max_gb > 0.0 ||
        config_error("[CONFIG] storage.max_storage_gb must be > 0 (got $max_gb).")
    t_start = parsed_datetime(
        required_value(sim, "simulation", "start_sim_time"),
        "simulation.start_sim_time",
    )
    seed = get(sim, "rng_seed", 0)
    (seed isa Integer && !(seed isa Bool)) ||
        config_error("[CONFIG] simulation.rng_seed must be an integer (got $(repr(seed))).")

    # -- [physics] --
    physics = physics_settings(cfg)
    segment_duration_sec = physics.segment_duration_sec
    n_samples = physics.sample_rate * segment_duration_sec
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
        if !isempty(physics.external_data_columns)
            header = csv_header(ext_path)
            missing_columns = setdiff(physics.external_data_columns, header)
            isempty(missing_columns) || config_error(
                "[CONFIG] physics.external_data_columns not found in $ext_path: $(join(missing_columns, ", ")) (header: $(join(header, ", "))).",
            )
        end
    end

    # -- [telemetry] --
    tel_settings = telemetry_settings(cfg)
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

    # -- Real-time pacing sanity (loop-scheduler corner cases; wall mode
    #    only — the tick clock has no sleep to distort) --
    if mode == "wall"
        emitter_period_ms = segment_duration_sec / speed_up * 1000.0
        if emitter_period_ms < EMITTER_PERIOD_WARN_MS
            @warn "[CONFIG] Emitter wall-clock period is $(round(emitter_period_ms, digits=2)) ms " *
                  "(segment_duration_sec / speed_up). Below $(EMITTER_PERIOD_WARN_MS) ms the generation loop cannot keep " *
                  "pace with the accelerated clock and batch timestamps desynchronize. " *
                  "Increase segment_duration_sec or decrease speed_up."
        end
        rx_slot_ms = tel_settings.nominal_batch_transfer_sec / speed_up * 1000.0
        if rx_slot_ms < RECEIVER_SLOT_WARN_MS
            @warn "[CONFIG] Receiver download slot is $(round(rx_slot_ms, digits=2)) ms " *
                  "(batch transfer time / speed_up). The $(RECEIVER_SLEEP_FLOOR_SEC * 1000) ms sleep floor distorts " *
                  "the effective downlink rate. Decrease speed_up or the link capacity."
        end
    end
    # -- [contacts], [[events.markers]], [[labels]], [ground], [post_processing.publication] --
    contacts_settings(cfg)
    label_settings(cfg)
    ground_settings(cfg)
    publication_settings(cfg)

    # -- on-board recorder against the contact schedule --
    capacity = onboard_capacity(cfg)
    if downtime > capacity.days
        @warn "[CONFIG] simulation.initial_downtime_days = $downtime exceeds the on-board recorder capacity ($(capacity.days) days): pre-populated batches beyond $(capacity.batches) are discarded."
    end
    t_end = t_start + Millisecond(round(Int, mission_days * MS_PER_DAY))
    windows = contact_windows(visibility_model(cfg), t_start, t_end)
    longest_gap_hours = 0.0
    previous_stop = t_start - Millisecond(round(Int, downtime * MS_PER_DAY))
    for w in windows
        longest_gap_hours =
            max(longest_gap_hours, (w.start - previous_stop).value / MS_PER_HOUR)
        previous_stop = max(previous_stop, w.stop)
    end
    # Data produced after the last contact accumulates until the mission end.
    longest_gap_hours = max(longest_gap_hours, (t_end - previous_stop).value / MS_PER_HOUR)
    if longest_gap_hours > 24 * capacity.days
        @warn "[CONFIG] The longest interval without ground contact ($(round(longest_gap_hours, digits = 1)) h) exceeds the on-board recorder capacity ($(24 * capacity.days) h of production): the emitter discards data once the buffer is full."
    end

    # -- [packet_loss] --
    loss = loss_channel_settings(cfg)
    events = disruption_event_settings(cfg)
    if loss.enabled
        if loss.model == "gilbert_elliott" && loss.p_bad_to_good == 0.0
            @warn "[CONFIG] packet_loss.p_bad_to_good = 0: once the channel enters the BAD state it never recovers."
        end
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
    dashboard_settings(cfg)
    post_processing = post_processing_settings(cfg)
    if post_processing.figures.state_raster && !post_processing.generate_mask_timeline
        @warn "[CONFIG] post_processing.state_raster = true with post_processing.generate_mask_timeline = false: the raster is drawn from the mask timeline and is skipped."
    end

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

# --- Component timing ---

"""
    RECEIVER_POLL_INTERVAL_SEC

Receiver idle-poll and metrics-tick interval [wall-clock s], and the
default polling period of `Supervisor.supervise!`.
"""
const RECEIVER_POLL_INTERVAL_SEC = 0.2

# Bandwidth change [percentage points] that admits a mission_profile.csv row.
const METRICS_BANDWIDTH_HYSTERESIS_PCT = 0.1

"""
    RECEIVER_SLEEP_FLOOR_SEC

Minimum receiver download-slot sleep [s], a property of the OS scheduler
rather than a tunable; [`RECEIVER_SLOT_WARN_MS`](@ref) is the slot below
which the validator warns that it distorts the download rate.
"""
const RECEIVER_SLEEP_FLOOR_SEC = 0.001

"""
    EMITTER_PERIOD_WARN_MS

Emitter wall-clock segment period `segment_duration_sec / speed_up` [ms]
below which [`validate_config`](@ref) warns: at shorter periods the
generation loop cannot keep pace with the accelerated clock and the batch
timestamps desynchronize from mission time.
"""
const EMITTER_PERIOD_WARN_MS = 5.0

"""
    RECEIVER_SLOT_WARN_MS

Receiver wall-clock download slot `nominal_batch_transfer_sec / speed_up`
[ms] below which [`validate_config`](@ref) warns: the
[`RECEIVER_SLEEP_FLOOR_SEC`](@ref) sleep floor then distorts the effective
downlink rate.
"""
const RECEIVER_SLOT_WARN_MS = 2.0

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
    HEARTBEAT_INTERVAL_MS

Wall-clock interval between two touches of a component's liveness file
[ms]; the supervisor's watchdog reads the file's modification time.
"""
const HEARTBEAT_INTERVAL_MS = 1000

const MS_PER_HOUR = 3_600_000
const MS_PER_DAY = 86_400_000

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

# --- Storage governance ---
const DEFAULT_WATERMARK_FRACTION = 0.75 # of the budget, without retention.high_watermark_gb
const STORAGE_WARN_FRACTION = 0.9 # of a [storage] budget: the pre-run gate warns above it
# Estimator calibration:
const MASK_ROW_OVERHEAD_BYTES = 32.0 # per mask-timeline row: timestamp column, separators
const LOG_FIXED_OVERHEAD_BYTES = 200_000.0 # log banners, startup and post-processing lines
const RUN_FILE_COUNT_SLACK = 8 # rotation backups and sentinels beyond the per-class counts

"""
    storage_budget(cfg::AbstractDict) -> (max_gb, max_files, max_ram_gb)

Resolves the run-directory disk budget [GB] and inode budget from `[storage]`.
The retired `simulation.max_storage_gb` is rejected with the replacement
named; without the key the default of 5.0 GB applies.
`max_ram_gb` (default 8.0) budgets the post-processing RAM: the replay and the figure stage.
"""
function storage_budget(cfg::AbstractDict)
    st = get(cfg, "storage", Dict{String,Any}())
    sim = get(cfg, "simulation", Dict{String,Any}())
    reject_removed_key(sim, "simulation", "max_storage_gb")
    max_gb = checked_number(get(st, "max_storage_gb", 5.0), "storage.max_storage_gb")
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
    log_rotate_bytes::Int
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
        Millisecond(round(Int, grace_hours * MS_PER_HOUR)),
        watermark_gb * 1024^3,
        round(Int, rotate_mb * 1024^2),
    )
end

"""
    estimate_artifacts(cfg::AbstractDict) -> NamedTuple

Closed-form per-class footprint of a run, from the configuration alone;
counts that depend on stochastic outcomes are upper bounds. The classes are
payload segment CSVs, batch metadata, event logs, metrics, the 2D mask
timeline, point-wise expansions, the HDF5 export, plots (the session and
summary figures and those of [`FIGURE_PRODUCTS`](@ref), each as PNG and
PDF; the optional GIF is a manual product and is excluded), and text logs.
The calibration constants are measured defaults
([`STORAGE_CALIBRATION_DEFAULTS`](@ref)), overridable key-by-key in
`[storage]`.

Returns the counts `n_segments`, `n_batches`, `n_points`, `n_columns`
(payload columns per segment file: one for a synthetic run, else the length
of `physics.external_data_columns`, at least one), `mission_days`, and
`metrics_rows`; the per-class byte fields, `total_bytes`, and `file_count`;
`replay_ram_bytes` and `figure_ram_bytes`, the RAM of the post-processing
replay and of the figure stage (one figure at a time), both gated against
`storage.max_ram_gb`; and the retention-prunable subset `prunable_bytes`,
`prunable_files`: the payload scaled by the expected delivered fraction
under the configured loss model. Metadata, event logs, metrics, masks, and
`lost/`, where terminally lost batches land, are not prunable.
"""
function estimate_artifacts(cfg::AbstractDict)
    sim = get(cfg, "simulation", Dict{String,Any}())
    phy = get(cfg, "physics", Dict{String,Any}())
    st = get(cfg, "storage", Dict{String,Any}())

    segment_duration_sec = checked_number(
        required_value(phy, "physics", "segment_duration_sec"),
        "physics.segment_duration_sec",
    )
    sample_rate =
        checked_number(required_value(phy, "physics", "sample_rate"), "physics.sample_rate")
    batch_size =
        checked_integer(required_value(phy, "physics", "batch_size"), "physics.batch_size")
    downtime_days = checked_number(
        get(sim, "initial_downtime_days", 0.0),
        "simulation.initial_downtime_days",
    )

    loss = loss_channel_settings(cfg)
    loss_enabled = loss.enabled
    retries = loss.enabled ? loss.max_retries : 0

    cal =
        key -> Float64(get(st, key, getproperty(STORAGE_CALIBRATION_DEFAULTS, Symbol(key))))

    sim_sec = mission_span_days(cfg) * 86_400.0
    total_sec_gen = sim_sec + downtime_days * 86_400.0
    n_segments = ceil(Int, total_sec_gen / segment_duration_sec)
    n_batches = ceil(Int, n_segments / batch_size)
    n_points = round(Int, n_segments * segment_duration_sec * sample_rate)
    mission_days = ceil(Int, sim_sec / 86_400.0)
    # Metrics rows are admitted on batch-count changes (≤ 4 per batch:
    # onboard, link, and ground/lost transitions plus slack) and on
    # bandwidth-hysteresis steps — one full 0 → peak → 0 pass admits up to
    # 2 × 100 / hysteresis rows per mission day.
    metrics_rows =
        4 * n_batches +
        2 * round(Int, 100.0 / METRICS_BANDWIDTH_HYSTERESIS_PCT) * max(mission_days, 1)

    # Each segment file holds one full column of samples per payload column.
    n_columns =
        get(phy, "data_source", "external") == "synthetic" ? 1 :
        max(1, length(get(phy, "external_data_columns", Any[])))
    # The flag series writes 0.0/1.0; anything else, an undeclared source
    # included, is sized as a full Float32 value, the upper bound.
    payload_bytes =
        n_points *
        n_columns *
        cal(
            get(phy, "data_source", "external") == "synthetic" ? "bytes_per_flag_sample" :
            "bytes_per_sample",
        )
    batch_meta_bytes = n_batches * cal("bytes_batch_metadata")
    # tx: gen + tx per batch; rx worst case: `retries` retry rows + one
    # terminal (ingested | lost) + one potential pruned row; the declared-hole
    # feed adds at most one row per batch.
    event_bytes =
        (2 * n_batches + n_batches * (retries + 2) + n_batches) * cal("bytes_event_row")
    metrics_bytes = metrics_rows * cal("bytes_metrics_row")

    post_processing = post_processing_settings(cfg)
    do_matrix = post_processing.generate_mask_timeline
    mask_bytes =
        do_matrix ?
        metrics_rows * (n_batches * cal("bytes_mask_cell") + MASK_ROW_OVERHEAD_BYTES) : 0.0

    do_expand = post_processing.expand_to_pointwise_masks
    target_rows = post_processing.target_event_rows
    # Branch on the concrete type: the union contract admits any Symbol, so a
    # type test narrows soundly where `=== :all` would not.
    n_expansions =
        do_expand ? (target_rows isa Vector{Int} ? length(target_rows) : metrics_rows) : 0
    pointwise_bytes = n_expansions * n_points * cal("bytes_pointwise_cell")
    # HDF5 export: a second copy of the tabular products and masks (the
    # binary layout is denser than CSV; the CSV sizes bound it).
    hdf5_bytes =
        post_processing.hdf5_export ?
        event_bytes + metrics_bytes + mask_bytes + pointwise_bytes : 0.0

    # Mission summary, the session figures, and one figure per enabled metric
    # or raster product. The same count sizes the plots directory and enters
    # the file count below.
    n_low_latency = length(contacts_settings(cfg).low_latency_periods)
    n_flagged_figures = count(values(post_processing.figures))
    # Session figures: one per day and per low-latency period, unless the
    # run switches them off or caps them.
    n_windows = mission_days + n_low_latency
    n_session_figures =
        !post_processing.session_figures ? 0 :
        post_processing.session_figures_max == 0 ? n_windows :
        min(post_processing.session_figures_max, n_windows)
    n_figures = 1 + n_session_figures + n_flagged_figures
    plot_bytes = n_figures * (cal("bytes_plot") + cal("bytes_plot_pdf"))
    log_bytes = n_batches * cal("bytes_log_per_batch") + LOG_FIXED_OVERHEAD_BYTES

    # Post-processing replay RAM: the exact replay materializes one category
    # membership per (metrics row x batch); the GIF is a manual product and
    # is excluded, matching the plots policy above.
    replay_ram_bytes =
        (do_matrix || do_expand) ? metrics_rows * n_batches * cal("bytes_replay_cell") : 0.0
    # Figure stage: every figure is released after saving, so the stage
    # holds one raster at a time plus the plot vertices of the mission
    # summary. These scale with the realized metrics rows: at most three per
    # batch (generation, transmission, ingestion), and at most metrics_rows.
    figure_rows = min(metrics_rows, 3 * n_batches)
    figure_ram_bytes = cal("bytes_figure_stage") + figure_rows * cal("bytes_figure_row")

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

    file_count =
        n_batches * (batch_size + 2) + # batch directory, metadata.json, segment CSVs
        2 + # event logs
        1 + # mission profile
        (do_matrix ? 1 : 0) +
        n_expansions +
        2 * n_figures + # PNG and PDF
        (hdf5_bytes > 0 ? 1 : 0) +
        3 + # emitter, receiver, and supervisor logs
        2 + # configuration and manifest snapshots
        2 + # sentinels
        6 + # run subdirectories
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
        n_columns = n_columns,
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
        figure_ram_bytes = figure_ram_bytes,
        prunable_bytes = payload_bytes * delivered_fraction,
        prunable_files = round(Int, n_segments * delivered_fraction),
    )
end

"""
    StorageBudgetError(msg::String)

Raised by [`check_storage_limits`](@ref) when the projected disk volume,
file count, or post-processing RAM (replay or figure stage) exceeds its
`[storage]` budget and no configured mitigation bounds it. `msg` carries
the `[STORAGE]` diagnosis: the estimate, the budget, and the remedies.
"""
struct StorageBudgetError <: Exception
    msg::String
end

Base.showerror(io::IO, e::StorageBudgetError) = print(io, e.msg)

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

The same logic gates `storage.max_file_count`, and the replay and the
figure-stage RAM estimates are each gated against `storage.max_ram_gb` (a
mitigation-free hard budget). Every abort is a [`StorageBudgetError`](@ref). Returns
`nothing`; called before any run directory is created.
"""
function check_storage_limits(cfg::AbstractDict)
    est = estimate_artifacts(cfg)
    budget = storage_budget(cfg)
    ret = retention_settings(cfg)
    to_gb = b -> round(b / 1024^3, digits = 4)

    @info "[STORAGE] Pre-run artifact estimate ($(est.n_segments) segments, $(est.n_batches) batches, $(est.mission_days) mission days):"
    @info "  -> Payload segment CSVs: $(to_gb(est.payload_bytes)) GB ($(est.n_points) samples × $(est.n_columns) columns)"
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
    @info "  -> Figure RAM:           $(to_gb(est.figure_ram_bytes)) GB (budget: $(budget.max_ram_gb) GB)"

    max_ram_bytes = budget.max_ram_gb * 1024^3
    if est.replay_ram_bytes > max_ram_bytes
        throw(
            StorageBudgetError(
                "[STORAGE] Post-processing replay RAM estimate ($(to_gb(est.replay_ram_bytes)) GB) exceeds storage.max_ram_gb ($(budget.max_ram_gb) GB). Reduce the mission span, disable post_processing.generate_mask_timeline, or raise storage.max_ram_gb.",
            ),
        )
    elseif est.replay_ram_bytes > STORAGE_WARN_FRACTION * max_ram_bytes
        @warn "[STORAGE] Post-processing replay RAM estimate ($(to_gb(est.replay_ram_bytes)) GB) is within $(round(Int, 100 * (1 - STORAGE_WARN_FRACTION))) % of storage.max_ram_gb ($(budget.max_ram_gb) GB)."
    end
    if est.figure_ram_bytes > max_ram_bytes
        throw(
            StorageBudgetError(
                "[STORAGE] Figure-stage RAM estimate ($(to_gb(est.figure_ram_bytes)) GB) exceeds storage.max_ram_gb ($(budget.max_ram_gb) GB). Raise storage.max_ram_gb.",
            ),
        )
    elseif est.figure_ram_bytes > STORAGE_WARN_FRACTION * max_ram_bytes
        @warn "[STORAGE] Figure-stage RAM estimate ($(to_gb(est.figure_ram_bytes)) GB) is within $(round(Int, 100 * (1 - STORAGE_WARN_FRACTION))) % of storage.max_ram_gb ($(budget.max_ram_gb) GB)."
    end

    max_bytes = budget.max_gb * 1024^3
    if !ret.enabled
        if est.total_bytes > max_bytes
            throw(
                StorageBudgetError(
                    "[STORAGE] Estimated storage ($(to_gb(est.total_bytes)) GB) exceeds the configured budget ($(budget.max_gb) GB) and no mitigation is active. Enable [retention], reduce the mission span, or raise storage.max_storage_gb.",
                ),
            )
        elseif est.file_count > budget.max_files
            throw(
                StorageBudgetError(
                    "[STORAGE] Estimated file count ($(est.file_count)) exceeds storage.max_file_count ($(budget.max_files)) and no mitigation is active. Enable [retention], reduce the mission span, or raise the budget.",
                ),
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
        throw(
            StorageBudgetError(
                "[STORAGE] Even with retention active, the steady-state footprint ($(to_gb(steady_bytes)) GB: non-prunable classes + payload capped at the $(to_gb(ret.watermark_bytes)) GB watermark) exceeds the configured budget ($(budget.max_gb) GB). Reduce the mission span, lower retention.high_watermark_gb, or raise storage.max_storage_gb.",
            ),
        )
    elseif steady_files > budget.max_files
        throw(
            StorageBudgetError(
                "[STORAGE] Even with retention active, the steady-state file count ($steady_files) exceeds storage.max_file_count ($(budget.max_files)).",
            ),
        )
    end
    if est.total_bytes > max_bytes
        @warn "[STORAGE] Unbounded projection ($(to_gb(est.total_bytes)) GB) exceeds the budget ($(budget.max_gb) GB); retention bounds the steady state to ≈ $(to_gb(steady_bytes)) GB — proceeding."
    end
    grace_sec = ret.grace.value / 1000.0
    grace_payload =
        est.payload_bytes / max(est.n_segments, 1) * (
            grace_sec / checked_number(
                required_value(
                    get(cfg, "physics", Dict{String,Any}()),
                    "physics",
                    "segment_duration_sec",
                ),
                "physics.segment_duration_sec",
            )
        )
    if grace_payload > ret.watermark_bytes
        @warn "[STORAGE] Payload generated within one retention.grace_hours window (≈ $(to_gb(grace_payload)) GB) exceeds retention.high_watermark_gb ($(to_gb(ret.watermark_bytes)) GB): the custodian cannot honor the grace guarantee and stay below the watermark; the watermark will be exceeded transiently."
    end
    @info "  -> Status: retention active — steady state ≈ $(to_gb(steady_bytes)) GB, ≈ $steady_files files"
    return nothing
end

# --- Mission clocks ---
"""
    MissionClock

The clock a mission runs on. [`SimulationClock`](@ref) paces mission time
against the wall clock (`simulation.mode = "wall"`); [`TickClock`](@ref)
advances it logically, from one component wakeup to the next
(`simulation.mode = "tick"`). The components read the current instant
through [`get_current_sim_time`](@ref), wait through [`wait_until!`](@ref),
[`wait_until_or_change!`](@ref), and the receiver's idle wait, and stop at
[`horizon_reached`](@ref); the mission's physics is expressed in mission
time and is the same under both.
"""
abstract type MissionClock end

"""
    SimulationClock(start_real_time::DateTime, start_sim_time::DateTime, speed_up::Float64) <: MissionClock

The accelerated mission clock: mission time advances `speed_up` times
faster than wall-clock time from the anchor pair `start_real_time` (the
wall instant of the anchor) and `start_sim_time` (the mission instant at
that anchor). [`get_current_sim_time`](@ref) maps the wall clock to mission
`SimTime`; [`due_wall_time`](@ref) is its inverse.
"""
struct SimulationClock <: MissionClock
    start_real_time::DateTime
    start_sim_time::DateTime
    speed_up::Float64
end

"""
    get_current_sim_time(clock::SimulationClock) -> DateTime

The current mission instant: `start_sim_time` plus `speed_up` times the wall
time elapsed since `start_real_time`, rounded to the millisecond.
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
the absolute wall-clock deadline into `<run_dir>/clock_anchor.toml`,
rotating an existing file to `clock_anchor#k.toml`. Written once at mission
start; a re-attaching or restarted component reconstructs the identical
clock from it ([`load_clock_anchor`](@ref)), so a component outage elapses
as mission time.
"""
function save_clock_anchor(run_dir::String, clock::SimulationClock, deadline::DateTime)
    path = joinpath(run_dir, "clock_anchor.toml")
    backup_existing(path)
    open(path, "w") do io
        TOML.print(
            io,
            Dict(
                "mode" => "wall",
                "wall_epoch" => string(clock.start_real_time),
                "start_sim_time" => string(clock.start_sim_time),
                "speed_up" => clock.speed_up,
                "deadline_wall" => string(deadline),
            ),
        )
    end
end

"""
    load_clock_anchor(run_dir::String) -> NamedTuple

Reconstructs the anchor persisted by [`save_clock_anchor`](@ref):
`(mode, clock, deadline, horizon)` with `mode` `"wall"` (also for anchors
written before the key existed) or `"tick"`, `clock` the
[`SimulationClock`](@ref) or the [`TickClock`](@ref) at its epoch,
`deadline` the absolute wall deadline of a wall run (`nothing` for a tick
run), and `horizon` the mission end of a tick run (`nothing` for a wall
run). Throws an `ArgumentError` when the anchor file is absent (runs
started by an older pipeline cannot be re-attached).
"""
function load_clock_anchor(run_dir::String)
    path = joinpath(run_dir, "clock_anchor.toml")
    isfile(path) || throw(
        ArgumentError(
            "[RUN] clock_anchor.toml missing in $run_dir — component re-attachment requires the persisted anchor written at mission start.",
        ),
    )
    a = TOML.parsefile(path)
    mode = String(get(a, "mode", "wall"))
    if mode == "tick"
        clock = TickClock(
            DateTime(a["start_sim_time"]),
            DateTime(a["horizon_sim"]);
            wall_epoch = DateTime(a["wall_epoch"]),
        )
        return (mode = mode, clock = clock, deadline = nothing, horizon = clock.horizon)
    end
    clock = SimulationClock(
        DateTime(a["wall_epoch"]),
        DateTime(a["start_sim_time"]),
        Float64(a["speed_up"]),
    )
    return (
        mode = mode,
        clock = clock,
        deadline = DateTime(a["deadline_wall"]),
        horizon = nothing,
    )
end

# --- Tick clock ---
"""
    TickWakeup

A parked component of the [`TickClock`](@ref): the mission instant `at` it
asked to resume at, its component `priority` (the emitter before the
receiver at an equal instant), the registration `sequence` breaking the
remaining ties, and the `release` channel the driver signals.
"""
struct TickWakeup
    at::DateTime
    priority::Int
    sequence::Int
    release::Channel{Nothing}
end

"""
    TickClock(start_sim_time::DateTime, horizon::DateTime; wall_epoch = now()) <: MissionClock

The logical mission clock of `simulation.mode = "tick"`. Mission time
advances only while every component task is parked, jumping to the earliest
requested wakeup, so a mission is a deterministic sequence of events for a
given seed and does not wait on the wall clock. `now_sim` is the current
instant, `horizon` the mission end (`start_sim_time + mission_days`), and
`wall_epoch` the wall instant of the start, kept for the anchor only. The
components are created by [`tick_spawn`](@ref), park through
[`wait_until!`](@ref), [`wait_until_or_change!`](@ref), and
[`wait_for_change!`](@ref), and are driven by [`run_ticks!`](@ref) on the
driver's thread.
"""
mutable struct TickClock <: MissionClock
    const start_sim_time::DateTime
    const horizon::DateTime
    const wall_epoch::DateTime
    now_sim::DateTime
    const wakeups::Vector{TickWakeup}
    sequence::Int
    const parked::Channel{Nothing}
end

function TickClock(
    start_sim_time::DateTime,
    horizon::DateTime;
    wall_epoch::DateTime = now(),
)
    horizon > start_sim_time || throw(
        ArgumentError(
            "[CLOCK] The tick horizon $horizon must lie after the mission epoch $start_sim_time.",
        ),
    )
    return TickClock(
        start_sim_time,
        horizon,
        wall_epoch,
        start_sim_time,
        TickWakeup[],
        0,
        Channel{Nothing}(1),
    )
end

"""
    save_clock_anchor(run_dir::String, clock::TickClock)

Persists the anchor of a tick-mode mission into `<run_dir>/clock_anchor.toml`,
rotating an existing file ([`backup_existing`](@ref)): `mode = "tick"`,
`wall_epoch`, the mission epoch `start_sim_time`, and the horizon
`horizon_sim`. A tick run has no wall deadline.
"""
function save_clock_anchor(run_dir::String, clock::TickClock)
    path = joinpath(run_dir, "clock_anchor.toml")
    backup_existing(path)
    open(path, "w") do io
        TOML.print(
            io,
            Dict(
                "mode" => "tick",
                "wall_epoch" => string(clock.wall_epoch),
                "start_sim_time" => string(clock.start_sim_time),
                "horizon_sim" => string(clock.horizon),
            ),
        )
    end
end

"""
    get_current_sim_time(clock::TickClock) -> DateTime

The current logical instant of the tick clock.
"""
get_current_sim_time(clock::TickClock) = clock.now_sim

"""
    horizon_reached(clock::MissionClock) -> Bool

Whether the mission clock has reached its horizon: never for the wall
clock, whose components hold the wall deadline themselves; for the tick
clock, once its instant equals the horizon.
"""
horizon_reached(::SimulationClock) = false
horizon_reached(clock::TickClock) = clock.now_sim >= clock.horizon

"""
    EMITTER_PRIORITY

Wakeup priority of the emitter under the [`TickClock`](@ref): at an equal
instant generation precedes service, as the instrument delivers a segment
after observing it and the ground serves what is on the link.
"""
const EMITTER_PRIORITY = 0

"""
    RECEIVER_PRIORITY

Wakeup priority of the receiver under the [`TickClock`](@ref), after the
emitter ([`EMITTER_PRIORITY`](@ref)).
"""
const RECEIVER_PRIORITY = 1

"""
    park!(clock::TickClock, at::DateTime, priority::Int)

Registers a wakeup of the calling task at `at` with `priority`, tells the
driver the task has parked, and blocks until the driver releases it.
"""
function park!(clock::TickClock, at::DateTime, priority::Int)
    release = Channel{Nothing}(1)
    clock.sequence += 1
    push!(clock.wakeups, TickWakeup(at, priority, clock.sequence, release))
    put!(clock.parked, nothing)
    take!(release)
    return nothing
end

"""
    earliest_wakeup(clock::TickClock) -> DateTime

The earliest instant a parked task asked to resume at, or the horizon when
none is parked.
"""
earliest_wakeup(clock::TickClock) =
    isempty(clock.wakeups) ? clock.horizon : minimum(w.at for w in clock.wakeups)

"""
    wait_until!(clock::MissionClock, sim_time::DateTime; deadline = nothing, floor_sec = 0.0, cap_sec = Inf, priority = 0)

Blocks the calling component until the mission clock reaches `sim_time`.
On the wall clock the wait is a sleep until [`due_wall_time`](@ref) of the
instant, clamped at the wall `deadline` when given, with the sleep length
clamped to `[floor_sec, cap_sec]` wall seconds so the caller's periodic
checks stay responsive (a zero-length sleep yields). On the tick clock the
task parks with a wakeup at `sim_time` (or now, if that is later) and
`priority`, and resumes once the driver has advanced the clock to it; the
keywords of the wall form are ignored.
"""
function wait_until!(
    clock::SimulationClock,
    sim_time::DateTime;
    deadline::Union{DateTime,Nothing} = nothing,
    floor_sec::Float64 = 0.0,
    cap_sec::Float64 = Inf,
    priority::Int = 0,
)
    due = due_wall_time(clock, sim_time)
    deadline !== nothing && (due = min(due, deadline))
    wait_sec = (due - now()).value / 1000.0
    sleep(clamp(wait_sec, floor_sec, cap_sec))
    return nothing
end
function wait_until!(clock::TickClock, sim_time::DateTime; priority::Int = 0, kwargs...)
    return park!(clock, max(sim_time, clock.now_sim), priority)
end

"""
    wait_until_or_change!(clock::MissionClock, sim_time::DateTime; kwargs...)

Like [`wait_until!`](@ref), but a wait that another component's activity
may cut short: on the wall clock the clamped sleep re-polls at `cap_sec` at
the latest; on the tick clock the task resumes at `sim_time` or at the next
wakeup of another component, whichever comes first. The receiver waits this
way for a deferred retransmission, so a batch placed on the link in the
meantime is served without waiting out the round trip.
"""
function wait_until_or_change!(clock::SimulationClock, sim_time::DateTime; kwargs...)
    return wait_until!(clock, sim_time; kwargs...)
end
function wait_until_or_change!(
    clock::TickClock,
    sim_time::DateTime;
    priority::Int = 0,
    kwargs...,
)
    return park!(clock, max(min(sim_time, earliest_wakeup(clock)), clock.now_sim), priority)
end

"""
    wait_for_change!(clock::TickClock; priority = 0)

Parks the calling task until the next wakeup of another component has run
(or the horizon, when none is parked): the receiver's idle wait under the
tick clock, where the link can only change when the emitter runs.
"""
function wait_for_change!(clock::TickClock; priority::Int = 0)
    return park!(clock, max(earliest_wakeup(clock), clock.now_sim), priority)
end

"""
    tick_spawn(clock::TickClock, priority::Int, f) -> Task

Creates the task of a component under the tick clock: `f()` starts when the
driver first releases the task, at the current instant with `priority`, and
the driver is told when the task parks or ends. The task runs on the
driver's thread, so the components interleave only at their waits.
"""
function tick_spawn(clock::TickClock, priority::Int, f)
    release = Channel{Nothing}(1)
    clock.sequence += 1
    push!(clock.wakeups, TickWakeup(clock.now_sim, priority, clock.sequence, release))
    return @async begin
        take!(release)
        try
            f()
        finally
            put!(clock.parked, nothing)
        end
    end
end

"""
    run_ticks!(clock::TickClock, tasks::Dict{Symbol,Task}; on_task_failed = (name, task) -> nothing)

The driver of the tick clock. It advances the clock to the earliest wakeup
(ties broken by component priority, then by registration order), releases
that task, waits until it parks again or ends, and repeats until no task is
parked. The clock stops at the horizon: a later wakeup resumes there, where
the component sees [`horizon_reached`](@ref) and leaves. A task that ended
with an exception is handed to `on_task_failed(name, task)` once; the
callback returns a replacement `Task` created by [`tick_spawn`](@ref),
which takes the name in `tasks`, or `nothing`. Runs on the calling task's
thread.
"""
function run_ticks!(
    clock::TickClock,
    tasks::Dict{Symbol,Task};
    on_task_failed = (name, task) -> nothing,
)
    failed = Set{Symbol}()
    while !isempty(clock.wakeups)
        _, i = findmin(w -> (w.at, w.priority, w.sequence), clock.wakeups)
        wake = clock.wakeups[i]
        deleteat!(clock.wakeups, i)
        clock.now_sim = min(max(clock.now_sim, wake.at), clock.horizon)
        put!(wake.release, nothing)
        take!(clock.parked)
        for (name, task) in collect(tasks)
            (istaskfailed(task) && !(name in failed)) || continue
            push!(failed, name)
            replacement = on_task_failed(name, task)
            if replacement isa Task
                tasks[name] = replacement
                delete!(failed, name)
            end
        end
    end
    return nothing
end

# --- Data Structures ---
"""
    PAYLOAD_COLUMN_DEFAULT

The name of the one payload column of a synthetic run and of an external
run without `physics.external_data_columns`: `Amplitude`.
"""
const PAYLOAD_COLUMN_DEFAULT = "Amplitude"

"""
    DataSegment(id::Int, timestamp::DateTime, data::Matrix{Float32}, columns::Vector{String})
    DataSegment(id::Integer, timestamp::DateTime, data::AbstractVector{<:Real})

One `segment_duration_sec` span of the observed time series: the `Float32`
samples `data`, one row per sample and one column per payload column named
in `columns`, the first sample at the mission instant `timestamp`. `id` is
the segment's position on the payload grid,
`(timestamp − origin) / segment_duration_sec + 1`
([`DeepSpaceTelemetry.VirtualInstrument.segment_id`](@ref)), unique within
a run. The vector form builds a one-column segment named
[`PAYLOAD_COLUMN_DEFAULT`](@ref). Throws a `DimensionMismatch` when `data`
does not have `length(columns)` columns and an `ArgumentError` when
`columns` is empty.
"""
struct DataSegment
    id::Int
    timestamp::DateTime
    data::Matrix{Float32}
    columns::Vector{String}
    function DataSegment(
        id::Int,
        timestamp::DateTime,
        data::Matrix{Float32},
        columns::Vector{String},
    )
        isempty(columns) &&
            throw(ArgumentError("A segment needs at least one payload column."))
        size(data, 2) == length(columns) || throw(
            DimensionMismatch(
                "segment $id holds $(size(data, 2)) columns for $(length(columns)) names.",
            ),
        )
        return new(id, timestamp, data, columns)
    end
end
DataSegment(id::Integer, timestamp::DateTime, data::AbstractVector{<:Real}) = DataSegment(
    Int(id),
    timestamp,
    reshape(Vector{Float32}(data), :, 1),
    [PAYLOAD_COLUMN_DEFAULT],
)

"""
    segment_column(seg::DataSegment, column::Union{Integer,AbstractString}) -> Vector{Float32}

The samples of one payload column of `seg`, by index or by name; an
`ArgumentError` names the columns when `column` is not one of them.
"""
function segment_column(seg::DataSegment, column::Union{Integer,AbstractString})
    j = if column isa AbstractString
        findfirst(==(column), seg.columns)
    else
        1 <= column <= length(seg.columns) ? Int(column) : nothing
    end
    j === nothing && throw(
        ArgumentError(
            "Segment $(seg.id) has no payload column $(repr(column)) (columns: $(join(seg.columns, ", "))).",
        ),
    )
    return seg.data[:, j]
end

"""
    DataBatch(id::Int, segments::Vector{DataSegment}, created_at::DateTime)

A collection of [`DataSegment`](@ref)s prepared for bulk transmission over
the DSN: `id` is the batch counter, `segments` the payload in content
order, and `created_at` the mission instant of finalization (when the
batch became transmittable; the content epoch is `segments[1].timestamp`).
"""
struct DataBatch
    id::Int
    segments::Vector{DataSegment}
    created_at::DateTime
end

# --- Mission metrics ---
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

    # Row-wise append: the profile is an append-only log of the run, so no
    # backup rotation applies to it.
    write_table(log_path, df; append = exists)
end

# --- Ground-Truth Event Logs ---
"""
    log_tx_event(run_dir::String, sim_t::DateTime, batch::String, event::String)

Appends one row to `events_tx.csv`. Events: `"gen"` (batch finalized
onboard), `"tx"` (batch placed on the downlink), `"marker"` (`sim_t` an
event-marker instant, `batch` the batch holding it), and the
`"gap_start"`/`"gap_end"` pair bounding a generation gap (`batch` =
`SCHEDULED`, `RECORDER`, or `STREAM`); marker and gap rows preserve the
batch states. With [`log_rx_event`](@ref) it records the exact per-batch
state history that the mask and animation reconstruction replays. The
emitter writes the file; the supervisor appends the `STREAM` pair only
while no emitter is live, so there is one writer at a time and no lock.
"""
function log_tx_event(run_dir::String, sim_t::DateTime, batch::String, event::String)
    path = joinpath(run_dir, "events_tx.csv")
    df = DataFrame(SimTime = sim_t, Batch = batch, Event = event)
    write_table(path, df; append = isfile(path))
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
    write_table(path, df; append = isfile(path))
end

# --- Declared-hole feed ---
"""
    HOLE_FEED_COLUMNS

The columns of `holes.csv`, the declared-hole feed: `DeclaredAt` (the
mission instant the hole was declared at), then the columns of the gap
table, `Cause`, `Batch`, `RowFirst`, `RowLast`, `ContentStart`,
`ContentEnd`.
"""
const HOLE_FEED_COLUMNS =
    (:DeclaredAt, :Cause, :Batch, :RowFirst, :RowLast, :ContentStart, :ContentEnd)

"""
    HoleFeed(run_dir, origin::DateTime, sample_rate::Real, points_per_batch::Integer)

The writer of `<run_dir>/holes.csv`, the declared-hole feed: one row per
hole of the delivered record, appended when its producer declares it. The
receiver declares lost and pruned batches, the emitter scheduled and
recorder gaps, and the supervisor emitter outages; after the mission phase
`Masks.settle_hole_feed!` appends the end-of-run holes, so that the feed of
a finished run and `masks/gaps.csv` hold the same holes. One instance is
shared by the components of a run, and `lock` serializes their appends,
which come from separate threads under the wall clock. The payload grid
(`origin`, `sample_rate`) and `points_per_batch` let a batch name alone fix
its rows. Consumers tail the file directly or through
[`read_hole_feed`](@ref) and `RunAdapter.declared_holes`.
"""
struct HoleFeed
    path::String
    origin::DateTime
    sample_rate::Float64
    points_per_batch::Int
    lock::ReentrantLock
end
HoleFeed(
    run_dir::AbstractString,
    origin::DateTime,
    sample_rate::Real,
    points_per_batch::Integer,
) = HoleFeed(
    joinpath(String(run_dir), "holes.csv"),
    origin,
    Float64(sample_rate),
    Int(points_per_batch),
    ReentrantLock(),
)

"""
    hole_feed(run_dir::String) -> HoleFeed

The feed of a run from its configuration snapshot: `payload_origin(cfg)`,
`physics.sample_rate`, and `points_per_batch` =
`round(Int, sample_rate × segment_duration_sec) × batch_size`.
"""
function hole_feed(run_dir::String)
    cfg = load_run_config(run_dir)
    physics = physics_settings(cfg)
    return HoleFeed(
        run_dir,
        payload_origin(cfg),
        physics.sample_rate,
        round(Int, physics.sample_rate * physics.segment_duration_sec) * physics.batch_size,
    )
end

"""
    declare_hole!(feed::HoleFeed, declared_at::DateTime, cause::AbstractString,
                  batch::Union{AbstractString,Missing}, rows::UnitRange{Int}) -> Bool

Appends one row to the feed: `declared_at`, `cause`, `batch` (`missing`
for a generation gap or the unreached tail), the inclusive `rows`, and
the content interval `[payload_row_time(first), payload_row_time(last + 1))`.
Returns `false` and writes nothing when `rows` is empty. The header is
written with the first row.
"""
function declare_hole!(
    feed::HoleFeed,
    declared_at::DateTime,
    cause::AbstractString,
    batch::Union{AbstractString,Missing},
    rows::UnitRange{Int},
)
    isempty(rows) && return false
    df = DataFrame(
        DeclaredAt = DateTime[declared_at],
        Cause = String[String(cause)],
        Batch = Union{Missing,String}[batch === missing ? missing : String(batch)],
        RowFirst = Int[first(rows)],
        RowLast = Int[last(rows)],
        ContentStart = DateTime[payload_row_time(
            feed.origin,
            feed.sample_rate,
            first(rows),
        )],
        ContentEnd = DateTime[payload_row_time(
            feed.origin,
            feed.sample_rate,
            last(rows) + 1,
        )],
    )
    lock(feed.lock) do
        write_table(feed.path, df; append = isfile(feed.path))
    end
    return true
end

"""
    declare_batch_hole!(feed::HoleFeed, declared_at::DateTime, cause::AbstractString, batch_dir::AbstractString) -> Bool

The hole of the batch at `batch_dir` (its name is the batch): rows from
the `payload_row` stamp of its metadata, or from its index when the stamp
is absent, over `points_per_batch` rows; `cause` is `lost` or `pruned`.
"""
function declare_batch_hole!(
    feed::HoleFeed,
    declared_at::DateTime,
    cause::AbstractString,
    batch_dir::AbstractString,
)
    name = basename(batch_dir)
    meta = read_batch_metadata(String(batch_dir))
    first_row = get(meta, "payload_row", nothing)
    first_row isa Integer || (first_row = (batch_id(name) - 1) * feed.points_per_batch + 1)
    return declare_hole!(
        feed,
        declared_at,
        cause,
        name,
        Int(first_row):(Int(first_row)+feed.points_per_batch-1),
    )
end

"""
    declare_gap_hole!(feed::HoleFeed, declared_at::DateTime, cause::AbstractString, start::DateTime, stop::DateTime) -> Bool

The hole of the generation gap `[start, stop)`: rows
`payload_time_row(start) … payload_time_row(stop) − 1`; `cause` is
`scheduled`, `recorder`, or `stream`. Nothing is written for an empty gap.
"""
function declare_gap_hole!(
    feed::HoleFeed,
    declared_at::DateTime,
    cause::AbstractString,
    start::DateTime,
    stop::DateTime,
)
    rows =
        payload_time_row(feed.origin, feed.sample_rate, start):(payload_time_row(
            feed.origin,
            feed.sample_rate,
            stop,
        )-1)
    return declare_hole!(feed, declared_at, cause, missing, rows)
end

"""
    read_hole_feed(run_dir::String; after::Integer = 0) -> DataFrame

The rows of `<run_dir>/holes.csv` beyond the first `after`, typed as
written (`DeclaredAt`, `ContentStart`, `ContentEnd` as `DateTime`); an
empty table with the feed's columns when the file is absent or holds no
further rows.
"""
function read_hole_feed(run_dir::String; after::Integer = 0)
    path = joinpath(run_dir, "holes.csv")
    isfile(path) || return DataFrame(
        DeclaredAt = DateTime[],
        Cause = String[],
        Batch = Union{Missing,String}[],
        RowFirst = Int[],
        RowLast = Int[],
        ContentStart = DateTime[],
        ContentEnd = DateTime[],
    )
    table = read_table(path)
    return after >= DataFrames.nrow(table) ? table[1:0, :] : table[(after+1):end, :]
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
    df = read_table(path)
    isempty(df) && return 0
    return maximum(batch_id(String(b)) for b in df.Batch)
end

# --- Backup rotation and table I/O ---
"""
    backup_existing_dir(path::String) -> Union{String, Nothing}

Directory counterpart of [`backup_existing`](@ref): renames an existing
directory to `<name>#<k>` (smallest unused `k`) with a `[SAFESAVE]`
warning, before a same-named arrival takes its place. Returns the backup
path, or `nothing` when `path` did not exist.
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

"""
    backup_existing(path::String) -> Union{String, Nothing}

If `path` exists, renames it to `<name>#<k><ext>` with the smallest unused
`k`: the backup rotation of DrWatson's `safesave`, without the dependency
(the manual's "Provenance conventions" table lists the correspondences).
Returns the backup path, or `nothing` if `path` did not exist.
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
    TIMESTAMP_COLUMNS

Columns of the run-directory tables that hold instants. [`read_table`](@ref)
reads them as `DateTime` whatever the CSV parser would infer, and
[`write_table`](@ref) writes every `DateTime` column in one fixed form.
"""
const TIMESTAMP_COLUMNS = (
    :DeclaredAt,
    :SimTime,
    :WallTime,
    :GenSimTime,
    :ContentEpoch,
    :ContentStart,
    :ContentEnd,
    :AvailableAt,
    :Marker,
)

"""
    timestamp_text(t) -> Union{String,Missing}

The lexical form of an instant in the run-directory tables:
`yyyy-mm-ddTHH:MM:SS.s`, the seconds with at least one and at most three
decimals (`2035-01-04T12:00:36.0`, `2026-09-24T02:01:17.051`). `missing`
stays `missing`.
"""
timestamp_text(t::DateTime) = Dates.format(t, Dates.ISODateTimeFormat)
timestamp_text(::Missing) = missing

"""
    read_table(path::AbstractString; kwargs...) -> DataFrame

Reads a table of the run directory with stated types: the columns of
[`TIMESTAMP_COLUMNS`](@ref) present in its header as `DateTime` (`missing`
where a field is empty) and every text column as `String`; numbers and
booleans are inferred. The inference of the CSV parser is not part of the
file contract: CSV.jl 1.x reads an ISO instant as a nanosecond timestamp
type and text as a string type of its own. `kwargs` are passed to
`CSV.read`.
"""
function read_table(path::AbstractString; kwargs...)
    header = Symbol.(strip.(split(readline(path), ',')))
    types =
        Dict{Symbol,Type}(name => DateTime for name in header if name in TIMESTAMP_COLUMNS)
    return CSV.read(path, DataFrame; types = types, stringtype = String, kwargs...)
end

"""
    write_table(path::AbstractString, table; append = false) -> String

Writes a table of the run directory, every `DateTime` column as text in the
form of [`timestamp_text`](@ref). That form is the one these files have
always carried and is part of the file contract; the default of the CSV
writer is not, and it changed between CSV.jl 0.10 and 1.x.
"""
function write_table(path::AbstractString, table; append::Bool = false)
    source = DataFrame(table; copycols = false)
    out = DataFrame()
    for name in names(source)
        column = source[!, name]
        out[!, name] =
            nonmissingtype(eltype(column)) === DateTime ? timestamp_text.(column) : column
    end
    CSV.write(path, out; append = append)
    return String(path)
end

"""
    safe_csv_write(path::String, table) -> String

Writes `table` to `path` as CSV, first rotating any pre-existing file to a
`#k`-suffixed backup via [`backup_existing`](@ref). Instants are written in
the fixed form of [`timestamp_text`](@ref). Returns `path`.
"""
function safe_csv_write(path::String, table)
    backup = backup_existing(path)
    backup !== nothing && @info "[SAFESAVE] Existing file backed up to: $backup"
    write_table(path, table)
    return path
end

# --- Run Management ---
"""
    config_sha256(cfg::AbstractDict) -> String

SHA-256, as 64 hex digits, of the configuration printed as sorted TOML
without its `provenance` section: the identity of the parameters alone,
the same on every host and for every run of one configuration.
"""
function config_sha256(cfg::AbstractDict)
    parameters =
        Dict{String,Any}(String(k) => v for (k, v) in cfg if String(k) != "provenance")
    return bytes2hex(sha256(sprint(io -> TOML.print(io, parameters; sorted = true))))
end

"""
    generate_run_id(cfg::AbstractDict) -> String

Run identifier `RUN_cfg=<8 hex>_pid=<pid>_t=<yyyymmdd_HHMMSS>`: the first
eight hex digits of [`config_sha256`](@ref), the process id, and the
wall-clock instant — key=value fields in alphabetical order, the layout of
DrWatson's `savename`. The hash makes the runs of one configuration
recognizable by name; the process id and the instant keep the identifier
unique.
"""
function generate_run_id(cfg::AbstractDict)
    return string(
        "RUN_cfg=",
        first(config_sha256(cfg), 8),
        "_pid=",
        getpid(),
        "_t=",
        Dates.format(now(), "yyyymmdd_HHMMSS"),
    )
end

"""
    platform_provenance() -> Dict{String,Any}

Hardware and runtime fingerprint stamped into every run's
`config_snapshot.toml` under `[provenance.platform]`: hostname, OS kernel
and architecture, CPU model and logical core count, total memory, Julia
version and `versioninfo()` report, thread and BLAS-thread counts, the
package version, and the source identity of [`source_identity`](@ref)
(`identity_source`, `git_commit`, `git_tree_sha1`, `git_dirty`, `repo_url`,
`repo_rev`), valid for a git checkout and a Pkg-installed copy alike. The
manifest is recorded beside the snapshot by [`save_manifest_snapshot`](@ref).
There are no GPU fields: the pipeline is I/O- and event-loop-bound and uses
no GPU backend.
"""
function platform_provenance()
    cpu = Sys.cpu_info()
    provenance = Dict{String,Any}(
        "package_version" => string(pkgversion(TelemetryCore)),
        "hostname" => Base.Libc.gethostname(),
        "os" => string(Sys.KERNEL, " ", Sys.MACHINE),
        "cpu_model" => isempty(cpu) ? "unknown" : cpu[1].model,
        "logical_cores" => Sys.CPU_THREADS,
        "total_memory_gb" => round(Sys.total_memory() / 1024^3; digits = 2),
        "julia_version" => string(VERSION),
        "versioninfo" => sprint(InteractiveUtils.versioninfo),
        "julia_threads" => Threads.nthreads(),
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
    )
    for (key, value) in pairs(source_identity())
        provenance[String(key)] = value
    end
    return provenance
end

"""
    source_identity(root = PROJECT_ROOT; manifest = active_manifest_path()) -> NamedTuple

The identity of the package source at `root`, stamped into
`[provenance.platform]` and copied into `descriptor.toml`:

- `identity_source` — how it was determined: `"work_tree"` when `root` is
  the top level of a git work tree ([`git_work_tree`](@ref)); `"manifest"`
  for an installed copy whose package UUID has an entry with a
  `git-tree-sha1` in the manifest `manifest` (the active environment's by
  default, [`active_manifest_path`](@ref)); `"directory"` otherwise.
- `git_commit` — the `HEAD` commit of the work tree; for an installed copy
  the entry's `repo-rev` when it is a full 40-digit commit hash, as in a
  `[sources]` pin by commit; empty otherwise (a branch or tag, a registry
  install, a bare directory).
- `git_tree_sha1` — the git tree hash of the source: `HEAD^{tree}` of the
  work tree, the entry's `git-tree-sha1`, or the hash of the directory
  itself ([`git_tree_sha1`](@ref)). Never empty, and the same value for the
  same content however the package was obtained.
- `git_dirty` — whether the code at `root` differs from that identity:
  uncommitted changes to tracked files of the work tree, or an installed
  directory whose tree hash differs from the entry's (with a warning).
  `false` for `"directory"`, whose identity is the content itself.
- `repo_url`, `repo_rev` — the entry's `repo-url` and `repo-rev`; empty
  unless `identity_source == "manifest"` and the copy was added by URL.

The directory hash leaves out `.git` and the data root ([`DATA_ROOT`](@ref))
when it lies inside `root`.

# Example
```julia
id = TelemetryCore.source_identity()
id.git_tree_sha1   # 40 hexadecimal digits, for a checkout and an installed copy alike
```
"""
function source_identity(
    root::AbstractString = PROJECT_ROOT;
    manifest::Union{AbstractString,Nothing} = active_manifest_path(),
)
    isdir(root) || throw(ArgumentError("[RUN] No package directory $root."))
    if git_work_tree(root)
        lines = split(something(git_output(`rev-parse HEAD 'HEAD^{tree}'`; root), ""), '\n')
        length(lines) == 2 || throw(
            ErrorException("[RUN] git rev-parse returned no commit and tree for $root."),
        )
        return (
            identity_source = "work_tree",
            git_commit = String(strip(lines[1])),
            git_tree_sha1 = String(strip(lines[2])),
            git_dirty = git_dirty(root),
            repo_url = "",
            repo_rev = "",
        )
    end
    content = git_tree_sha1(root; exclude = [DATA_ROOT[]])
    entry = manifest_entry(root, manifest)
    if entry === nothing || isempty(string(get(entry, "git-tree-sha1", "")))
        return (
            identity_source = "directory",
            git_commit = "",
            git_tree_sha1 = content,
            git_dirty = false,
            repo_url = "",
            repo_rev = "",
        )
    end
    recorded = string(entry["git-tree-sha1"])
    rev = string(get(entry, "repo-rev", ""))
    dirty = content != recorded
    dirty &&
        @warn "[RUN] The package directory $root does not match its manifest entry (git-tree-sha1 $recorded, directory $content): recorded as git_dirty."
    return (
        identity_source = "manifest",
        git_commit = occursin(r"^[0-9a-f]{40}$", rev) ? rev : "",
        git_tree_sha1 = recorded,
        git_dirty = dirty,
        repo_url = string(get(entry, "repo-url", "")),
        repo_rev = rev,
    )
end

"""
    active_manifest_path(project = Base.active_project()) -> Union{String,Nothing}

The manifest of the environment whose project file is `project`, resolved
as Julia's code loading resolves it (a workspace root, a `manifest` key,
the version-specific `Manifest-vX.Y.toml` before `Manifest.toml`), or
`nothing` when there is no project or no manifest.
"""
function active_manifest_path(
    project::Union{AbstractString,Nothing} = Base.active_project(),
)
    project === nothing && return nothing
    return Base.project_file_manifest_path(String(project))
end

"""
    manifest_entry(root, manifest) -> Union{Dict{String,Any},Nothing}

The entry of the manifest file `manifest` for the package whose project file
lies at `root`, matched by name and UUID, or `nothing` when either file or
the entry is absent. Reads both the current manifest format (`[[deps.Name]]`)
and the format before Julia 1.7 (`[[Name]]`).
"""
function manifest_entry(root::AbstractString, manifest::Union{AbstractString,Nothing})
    manifest === nothing && return nothing
    projects = joinpath.(root, ("JuliaProject.toml", "Project.toml"))
    found = findfirst(isfile, projects)
    (found === nothing || !isfile(manifest)) && return nothing
    project = TOML.parsefile(projects[found])
    name = get(project, "name", nothing)
    uuid = tryparse(Base.UUID, string(get(project, "uuid", "")))
    (name isa String && uuid !== nothing) || return nothing
    content = TOML.parsefile(manifest)
    deps = haskey(content, "manifest_format") ? get(content, "deps", Dict()) : content
    for entry in get(deps, name, Any[])
        entry isa Dict{String,Any} || continue
        tryparse(Base.UUID, string(get(entry, "uuid", ""))) == uuid && return entry
    end
    return nothing
end

"""
    git_tree_sha1(dir::AbstractString; exclude = String[]) -> String

The git tree hash (40 hexadecimal digits) of the directory `dir` as git
would record it if every file under it were committed: entries in git's
order, modes `100644`, `100755` (owner-executable), `120000` (symbolic link,
hashed as its target) and `40000` (directory), empty directories and `.git`
entries left out, as `git write-tree` and Pkg do. The hash of an unmodified
installed copy therefore equals the `git-tree-sha1` of its manifest entry
and `git rev-parse <commit>^{tree}` of the commit it was installed from.
The paths in `exclude` are left out with everything under them.
"""
function git_tree_sha1(
    dir::AbstractString;
    exclude::AbstractVector{<:AbstractString} = String[],
)
    isdir(dir) || throw(ArgumentError("[RUN] No directory $dir to hash."))
    excluded = Set{String}(normpath(abspath(p)) for p in exclude if !isempty(p))
    entries = git_tree_entries(normpath(abspath(dir)), excluded)
    return bytes2hex(git_tree_digest(entries))
end

"""
    git_tree_entries(dir, excluded) -> Vector{Tuple{String,String,Vector{UInt8}}}

The `(mode, name, object hash)` entries of the git tree of `dir`, in git's
order (a directory sorts as its name followed by `/`).
"""
function git_tree_entries(dir::String, excluded::Set{String})
    entries = Tuple{String,String,Vector{UInt8}}[]
    for name in readdir(dir)
        path = joinpath(dir, name)
        (name == ".git" || path in excluded) && continue
        if islink(path)
            push!(entries, ("120000", name, git_blob_digest(codeunits(readlink(path)))))
        elseif isdir(path)
            children = git_tree_entries(path, excluded)
            isempty(children) || push!(entries, ("40000", name, git_tree_digest(children)))
        elseif isfile(path)
            executable = @static if Sys.iswindows()
                Sys.isexecutable(path)
            else
                !iszero(filemode(path) & 0o100)
            end
            push!(entries, (executable ? "100755" : "100644", name, git_blob_digest(path)))
        end
    end
    sort!(entries; by = e -> e[1] == "40000" ? string(e[2], '/') : e[2])
    return entries
end

"""
    git_tree_digest(entries) -> Vector{UInt8}

The SHA-1 of the git tree object made of `entries` ([`git_tree_entries`](@ref)).
"""
function git_tree_digest(entries::Vector{Tuple{String,String,Vector{UInt8}}})
    body = IOBuffer()
    for (mode, name, digest) in entries
        write(body, mode, ' ', name, '\0', digest)
    end
    bytes = take!(body)
    context = SHA.SHA1_CTX()
    SHA.update!(context, codeunits(string("tree ", length(bytes), '\0')))
    SHA.update!(context, bytes)
    return SHA.digest!(context)
end

"""
    git_blob_digest(source) -> Vector{UInt8}

The SHA-1 of the git blob object holding `source`: the bytes of a file path,
read in chunks, or a byte vector (the target of a symbolic link).
"""
function git_blob_digest(bytes::AbstractVector{UInt8})
    context = SHA.SHA1_CTX()
    SHA.update!(context, codeunits(string("blob ", length(bytes), '\0')))
    SHA.update!(context, bytes)
    return SHA.digest!(context)
end

function git_blob_digest(path::String)
    context = SHA.SHA1_CTX()
    SHA.update!(context, codeunits(string("blob ", filesize(path), '\0')))
    buffer = Vector{UInt8}(undef, 1 << 16)
    open(path) do io
        while !eof(io)
            n = readbytes!(io, buffer)
            SHA.update!(context, buffer, n)
        end
    end
    return SHA.digest!(context)
end

"""
    git_work_tree(root = PROJECT_ROOT) -> Bool

Whether `root` is the top level of a git work tree with a commit at `HEAD`;
`false` when git is not installed. A directory inside another repository
does not count, since an installed copy under a version-controlled depot
would otherwise be given that repository's commit.
"""
function git_work_tree(root::AbstractString = PROJECT_ROOT)
    top = git_output(`rev-parse --show-toplevel`; root)
    (top === nothing || isempty(top) || realpath(top) != realpath(root)) && return false
    return git_output(`rev-parse --verify --quiet HEAD`; root) !== nothing
end

"""
    git_commit(root = PROJECT_ROOT) -> String

The `HEAD` commit of the git work tree at `root`, or `""` when `root` is not
one ([`git_work_tree`](@ref)). [`source_identity`](@ref) covers installed
copies as well.
"""
function git_commit(root::AbstractString = PROJECT_ROOT)
    git_work_tree(root) || return ""
    return something(git_output(`rev-parse HEAD`; root), "")
end

"""
    git_dirty(root = PROJECT_ROOT) -> Bool

Whether the git work tree at `root` carries uncommitted changes to tracked
files (`git status --porcelain --untracked-files=no`); `false` when `root` is
not a work tree ([`git_work_tree`](@ref)). A run made from a dirty tree is
not reproducible from its recorded commit alone.
"""
function git_dirty(root::AbstractString = PROJECT_ROOT)
    git_work_tree(root) || return false
    status = git_output(`status --porcelain --untracked-files=no`; root)
    return !isempty(something(status, ""))
end

"""
    git_output(arguments::Cmd; root = PROJECT_ROOT) -> Union{String,Nothing}

Standard output of `git -C <root> <arguments>`, stripped, or `nothing` when
git is not installed or the command fails (no repository).
"""
function git_output(arguments::Cmd; root::AbstractString = PROJECT_ROOT)
    try
        command = `git -C $root $arguments`
        return String(strip(read(pipeline(command; stderr = devnull), String)))
    catch e
        e isa Union{Base.IOError,ProcessFailedException} || rethrow()
        return nothing
    end
end

"""
    save_manifest_snapshot(run_dir::String) -> Union{String,Nothing}

Copies the manifest of the active environment ([`active_manifest_path`](@ref))
to `<run_dir>/manifest_snapshot.toml`, so the run records the dependency
versions it was resolved on; manifests are not tracked in the repository.
Returns the snapshot path, or `nothing` with a warning when the active
environment has no manifest.
"""
function save_manifest_snapshot(run_dir::String)
    manifest = active_manifest_path()
    if manifest === nothing
        @warn "[RUN] The active environment has no manifest — dependency versions of this run are not recorded."
        return nothing
    end
    snapshot_path = joinpath(run_dir, "manifest_snapshot.toml")
    backup_existing(snapshot_path)
    cp(manifest, snapshot_path)
    return snapshot_path
end

"""
    setup_run_dir(run_id::String; cfg = nothing) -> String

Creates and returns the run directory of `run_id` with its subdirectories
`onboard`, `link`, `ground`, `lost`, `plots`, and `masks`; a directory under
the same run ID that holds anything but dotfiles is rejected with an
`ArgumentError`. Given the parsed configuration `cfg`, it writes
`config_snapshot.toml` (rotating an existing one, [`backup_existing`](@ref))
so that the run's parameters survive later edits of `config.toml`. The
snapshot adds the [`platform_provenance`](@ref) fingerprint under
`[provenance.platform]` and the parameter hash [`config_sha256`](@ref) at
`provenance.config_sha256`; the manifest of the active environment is
copied beside it ([`save_manifest_snapshot`](@ref)).
"""
function setup_run_dir(run_id::String; cfg::Union{AbstractDict,Nothing} = nothing)
    base_dir = run_directory(run_id)
    # Run-ID reuse guard (silent-failure mode): a reused ID would interleave
    # two missions' rows in mission_profile.csv and truncate the prior logs.
    if isdir(base_dir) && !isempty(filter(f -> !startswith(f, "."), readdir(base_dir)))
        throw(
            ArgumentError(
                "[RUN] Run directory $base_dir already exists and is non-empty — run IDs must be unique. Choose a new run ID or purge the previous run (scripts/maintenance/cleanup.jl).",
            ),
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
        prov["config_sha256"] = config_sha256(cfg)
        snapshot["provenance"] = prov
        snapshot_path = joinpath(base_dir, "config_snapshot.toml")
        backup_existing(snapshot_path)
        open(snapshot_path, "w") do io
            TOML.print(io, snapshot)
        end
        save_manifest_snapshot(base_dir)
    end
    return base_dir
end

# --- Batch & Segment I/O ---
"""
    save_batch(path::String, batch::DataBatch; markers = String[], payload_row = nothing)

Writes `batch` into the directory `path`: `metadata.json` and one
`seg_<id>.csv` per segment ([`save_segment`](@ref)), one column per payload
column. The metadata carries `batch_id`, `segment_count`, `created_at` (the
mission instant the batch was finalized and became transmittable),
`content_epoch` (the mission timestamp of its first sample, the physical
epoch of the data), and, when given, `payload_row` (the 1-based row of that
sample in the payload series starting at the payload origin) and `markers`
(the labels of the event markers whose instant lies in the payload).
"""
function save_batch(
    path::String,
    batch::DataBatch;
    markers::Vector{String} = String[],
    payload_row::Union{Int,Nothing} = nothing,
)
    mkpath(path)
    content_epoch = isempty(batch.segments) ? batch.created_at : batch.segments[1].timestamp
    metadata = Dict{String,Any}(
        "batch_id" => batch.id,
        "segment_count" => length(batch.segments),
        "created_at" => string(batch.created_at),
        "content_epoch" => string(content_epoch),
    )
    payload_row === nothing || (metadata["payload_row"] = payload_row)
    isempty(markers) || (metadata["markers"] = markers)
    open(joinpath(path, "metadata.json"), "w") do io
        JSON.json(io, metadata)
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
        JSON.parse(read(path, String); dicttype = Dict{String,Any})
    catch e
        @warn "[BATCH] Unparsable metadata.json in $batch_dir — treated as unknown." exception =
            e
        return Dict{String,Any}()
    end
    return parsed
end

"""
    batch_metadata_values(parse_value, run_dir::String, key::String, T::Type) -> Dict{String,T}

Batch name → `parse_value(meta[key])` for every batch directory under
`onboard/`, `link/`, `ground/`, and `lost/` whose `metadata.json` records
`key`; batches without the key, or whose value `parse_value` maps to
`nothing`, are omitted.
"""
function batch_metadata_values(parse_value, run_dir::String, key::String, T::Type)
    found = Dict{String,T}()
    for sub in ("onboard", "link", "ground", "lost")
        dir = joinpath(run_dir, sub)
        isdir(dir) || continue
        for name in readdir(dir)
            batch_dir = joinpath(dir, name)
            isdir(batch_dir) || continue
            meta = read_batch_metadata(batch_dir)
            haskey(meta, key) || continue
            value = parse_value(meta[key])
            value === nothing || (found[name] = value)
        end
    end
    return found
end

"""
    batch_content_epochs(run_dir::String) -> Dict{String,DateTime}

Batch name → content epoch (first-sample mission timestamp) for every batch
directory under `onboard/`, `link/`, `ground/`, and `lost/` whose
`metadata.json` records a `content_epoch` (batches written before that key
existed are omitted).
"""
function batch_content_epochs(run_dir::String)
    return batch_metadata_values(
        v -> tryparse(DateTime, string(v)),
        run_dir,
        "content_epoch",
        DateTime,
    )
end

"""
    batch_payload_rows(run_dir::String) -> Dict{String,Int}

Batch name → payload row of the first sample for every batch directory
under `onboard/`, `link/`, `ground/`, and `lost/` whose `metadata.json`
records a `payload_row` (batches written before 2.1.0 are omitted).
"""
function batch_payload_rows(run_dir::String)
    return batch_metadata_values(
        v -> v isa Integer ? Int(v) : nothing,
        run_dir,
        "payload_row",
        Int,
    )
end

"""
    save_segment(path::String, seg::DataSegment)

Writes the samples of `seg` to the CSV at `path`, one column per payload
column under its name. A segment named [`PAYLOAD_COLUMN_DEFAULT`](@ref)
writes the single `Amplitude` column of releases before 2.6.0.
"""
function save_segment(path::String, seg::DataSegment)
    df = DataFrame([seg.data[:, j] for j in 1:length(seg.columns)], seg.columns)
    write_table(path, df)
end

"""
    load_segment(path::String; timestamp::DateTime = DateTime(0)) -> DataSegment

Reads a segment CSV written by [`save_segment`](@ref) back into a
[`DataSegment`](@ref), one payload column per file column under its header
name; the identifier comes from the file name `seg_<id>.csv` (0 when it does
not conform). A non-numeric column raises an `ArgumentError` naming the file
and the column. The file holds samples only, so a caller that knows the
mission timestamp passes it as `timestamp` (the batch's `content_epoch` in
`metadata.json` is that of its first segment); the default `DateTime(0)`
marks it unknown.
"""
function load_segment(path::String; timestamp::DateTime = DateTime(0))
    df = read_table(path)
    id_match = match(r"seg_(\d+)\.csv", basename(path))
    # The capture is a Union{Nothing, SubString}: guard the full chain so a
    # nonconforming filename degrades to id 0 instead of throwing.
    id = id_match !== nothing ? something(tryparse(Int, something(id_match[1], "")), 0) : 0
    columns = String.(names(df))
    data = Matrix{Float32}(undef, DataFrames.nrow(df), length(columns))
    for j in eachindex(columns)
        column = df[!, j]
        eltype(column) <: Real || throw(
            ArgumentError(
                "Segment file $path: column $(columns[j]) is not numeric (eltype $(eltype(column))).",
            ),
        )
        data[:, j] = Vector{Float32}(column)
    end
    return DataSegment(id, timestamp, data, columns)
end

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

end # module TelemetryCore
