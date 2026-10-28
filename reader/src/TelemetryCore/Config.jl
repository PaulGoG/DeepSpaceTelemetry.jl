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
        path =
            isfile("config.toml") ? "config.toml" : joinpath(PROJECT_ROOT[], "config.toml")
    elseif !isabspath(path) && !isfile(path)
        # Root fallback, as for contacts.schedule_csv, so that
        # `run_full_sim.jl scenario.toml` works from any directory.
        candidate = joinpath(PROJECT_ROOT[], path)
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

Measured calibration constants of [`estimate_artifacts`](@ref): per-artifact
disk sizes [bytes], and the RAM of the replay (`bytes_replay_cell`, per
metrics row × batch membership) and of the figure stage
(`bytes_figure_stage`, `bytes_figure_row`). A `[storage]` key of the same
name still overrides a constant, but that override is deprecated since 2.7.0
and is removed in 3.0; [`validate_config`](@ref) warns when one is present.
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

The values of `simulation.mode`: `"wall"`, the operational mode, on the
[`TickClock`](@ref) paced against the wall clock at `speed_up` for
`mission_wall_seconds`, and `"tick"`, the analysis mode on the unpaced
logical clock spanning `mission_days`.
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
    gilbert_elliott_loss_rate(p_good_to_bad, p_bad_to_good, p_loss_good, p_loss_bad;
                              in_bad_state = false) -> Float64

Stationary loss probability of the two-state Gilbert–Elliott channel,
`π_bad·p_loss_bad + (1 − π_bad)·p_loss_good` with the stationary occupancy
`π_bad = p_good_to_bad / (p_good_to_bad + p_bad_to_good)`. A channel with
both transition probabilities zero keeps the loss probability of the state
it is in (`in_bad_state`; a channel starts in the good state).
"""
function gilbert_elliott_loss_rate(
    p_good_to_bad::Real,
    p_bad_to_good::Real,
    p_loss_good::Real,
    p_loss_bad::Real;
    in_bad_state::Bool = false,
)
    denom = p_good_to_bad + p_bad_to_good
    denom == 0 && return Float64(in_bad_state ? p_loss_bad : p_loss_good)
    pi_bad = p_good_to_bad / denom
    return Float64(pi_bad * p_loss_bad + (1 - pi_bad) * p_loss_good)
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
    samples_per_segment(sample_rate, segment_duration_sec) -> Int

Number of samples in one segment, `sample_rate × segment_duration_sec`
rounded to the nearest integer. `ArgumentError` when the product is below
one: the sample period would exceed the segment.
"""
function samples_per_segment(sample_rate::Real, segment_duration_sec::Real)
    product = sample_rate * segment_duration_sec
    product >= 1 || throw(
        ArgumentError(
            "sample_rate × segment_duration_sec must be ≥ 1 sample per segment (got $product).",
        ),
    )
    return round(Int, product)
end

"""
    points_per_batch(physics) -> Int

Payload rows of one batch,
`samples_per_segment(sample_rate, segment_duration_sec) · batch_size`, from
the `[physics]` settings ([`physics_settings`](@ref)) or any object with
those three fields. The one definition behind the descriptor, the hole
feed, the gap table, the adapter and the point-wise masks.
"""
points_per_batch(physics) =
    samples_per_segment(physics.sample_rate, physics.segment_duration_sec) *
    physics.batch_size

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
        "points_per_batch" => points_per_batch(physics),
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
`max_restarts ≥ 0` (default 3), `watchdog_sec > 0` (default 30). The
watchdog was retired with the second execution model in 2.8.0, so
`watchdog_sec` is validated but has no effect.
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
            joinpath(PROJECT_ROOT[], schedule_csv)
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
