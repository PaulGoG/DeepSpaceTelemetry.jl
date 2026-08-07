module TelemetryCore

using Dates, JSON3, CSV, DataFrames, TOML
using DrWatson

# --- Constants ---
"""
    L_ARM

Length of the LISA constellation arms (2.5 million kilometers).
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

const PROJECT_ROOT = let
    try
        DrWatson.projectdir()
    catch
        abspath(joinpath(@__DIR__, ".."))
    end
end

"""
    DATA_ROOT

Base directory for run storage (a `Ref`; default `<PROJECT_ROOT>/data`).
Every run-directory path resolves through [`run_directory`](@ref); tests and
embedding applications may redirect it (e.g. to a temporary directory).
"""
const DATA_ROOT = Ref(joinpath(PROJECT_ROOT, "data"))

"""
    run_directory(run_id::String) -> String

Canonical run-directory path `<DATA_ROOT>/runs/<run_id>` — the single source
of the run layout for components, scripts, and post-processing tools.
"""
run_directory(run_id::String) = joinpath(DATA_ROOT[], "runs", run_id)

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
        error("[CONFIG] $name must be a number (got $(repr(v))).")
    return Float64(v)
end

"""
    checked_integer(v, name::String) -> Int

Coerces a config value to `Int` with a clean `[CONFIG]` error on non-integer
TOML values (strings, floats, booleans).
"""
function checked_integer(v, name::String)
    (v isa Integer && !(v isa Bool)) ||
        error("[CONFIG] $name must be an integer (got $(repr(v))).")
    return Int(v)
end

"""
    checked_string(v, name::String) -> String

Coerces a config value to `String` with a clean `[CONFIG]` error when the
TOML value is not a string.
"""
function checked_string(v, name::String)
    v isa AbstractString || error("[CONFIG] $name must be a string (got $(repr(v))).")
    return String(v)
end

"""
    normalize_target_rows(raw) -> Union{Symbol, Vector{Int}}

Parses the `post_processing.target_event_rows` configuration entry into a
canonical form. Accepts the bare string `"all"`, or an array mixing integer row
indices (`-1` meaning the final row), `"start:stop"` range strings, and the
string `"all"`. Returns the symbol `:all` when every row is requested,
otherwise a sorted vector of unique row indices. Unrecognized entries are
skipped with a warning.
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
const KNOWN_CONFIG_KEYS = Dict(
    "simulation" => [
        "speed_up",
        "start_sim_time",
        "test_duration_sec",
        "initial_downtime_days",
        "rng_seed",
        "max_storage_gb",
    ],
    "storage" => [
        "max_storage_gb",
        "max_file_count",
        "bytes_per_sample",
        "bytes_batch_metadata",
        "bytes_event_row",
        "bytes_metrics_row",
        "bytes_mask_cell",
        "bytes_pointwise_cell",
        "bytes_plot",
        "bytes_log_per_batch",
    ],
    "retention" => ["enabled", "grace_hours", "high_watermark_gb", "log_rotate_mb"],
    "telemetry" => [
        "session_start",
        "session_duration_hours",
        "max_batches_per_hour",
        "bandwidth_profile",
        "max_inflight_batches",
        "min_link_factor",
        "sigmoid_steepness",
        "gaussian_sigma",
    ],
    "physics" => [
        "data_source",
        "external_data_path",
        "sample_rate",
        "segment_duration_sec",
        "batch_size",
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
    "post_processing" =>
        ["generate_batch_matrix", "expand_to_pointwise_masks", "target_event_rows"],
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
]

"""
    validate_config(cfg::AbstractDict)

Validates every tunable against its safe interval (documented inline in
`config.toml`) before any directory is created or any computation starts.
Code-breaking values raise an `error` (early termination); suspicious but
runnable values emit a `@warn`. Returns `cfg` for chaining.

Hard errors (would break the pipeline):
  - non-positive `speed_up`, `test_duration_sec`, `sample_rate`,
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
  - non-integer `sample_rate * segment_duration_sec` (rounded)
  - Gilbert–Elliott `p_bad_to_good = 0` (the channel never recovers)
  - disruption events starting at or after mission end (never fire), events
    whose blackout + recovery tail is truncated by mission end, blackouts
    spanning the entire remaining mission, and events overlapping in time
    (capacity composes as the minimum, loss multiplier as the maximum)
  - unrecognized sections or keys anywhere in the config (typo guard — an
    unknown key would otherwise silently fall back to its default)
  - `p_loss·multiplier ≥ 1` in a blackout-free config region (every transfer
    fails until retry exhaustion)
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

    sim = get(cfg, "simulation", Dict{String,Any}())
    tel = get(cfg, "telemetry", Dict{String,Any}())
    phy = get(cfg, "physics", Dict{String,Any}())

    # Required keys (R1 policy): a missing core tunable is a configuration
    # error, never a silently invented default.
    for (section, sec_name, required) in (
        (sim, "simulation", ("speed_up", "start_sim_time", "test_duration_sec")),
        (
            tel,
            "telemetry",
            ("session_start", "session_duration_hours", "max_batches_per_hour"),
        ),
        (
            phy,
            "physics",
            ("data_source", "sample_rate", "segment_duration_sec", "batch_size"),
        ),
    )
        for key in required
            haskey(section, key) || error("[CONFIG] Missing required key $sec_name.$key.")
        end
    end

    # -- [simulation] --
    speed_up = checked_number(get(sim, "speed_up", 0.0), "simulation.speed_up")
    speed_up > 0.0 || error("[CONFIG] simulation.speed_up must be > 0 (got $speed_up).")
    test_dur =
        checked_number(get(sim, "test_duration_sec", 0.0), "simulation.test_duration_sec")
    test_dur > 0.0 ||
        error("[CONFIG] simulation.test_duration_sec must be > 0 (got $test_dur).")
    downtime = checked_number(
        get(sim, "initial_downtime_days", 0.0),
        "simulation.initial_downtime_days",
    )
    downtime >= 0.0 ||
        error("[CONFIG] simulation.initial_downtime_days must be ≥ 0 (got $downtime).")
    # Budget positivity is checked through storage_budget so both the
    # [storage] location and the deprecated [simulation] fallback are covered.
    max_gb = storage_budget(cfg).max_gb
    max_gb > 0.0 || error("[CONFIG] storage.max_storage_gb must be > 0 (got $max_gb).")
    haskey(sim, "start_sim_time") ||
        error("[CONFIG] simulation.start_sim_time is required.")
    try
        DateTime(sim["start_sim_time"])
    catch
        error(
            "[CONFIG] simulation.start_sim_time is not a parseable ISO datetime: $(sim["start_sim_time"])",
        )
    end
    seed = get(sim, "rng_seed", 0)
    (seed isa Integer && !(seed isa Bool)) ||
        error("[CONFIG] simulation.rng_seed must be an integer (got $(repr(seed))).")

    # -- [physics] --
    sr = checked_number(get(phy, "sample_rate", 0.0), "physics.sample_rate")
    sr > 0.0 || error("[CONFIG] physics.sample_rate must be > 0 (got $sr).")
    seg_dur = checked_number(
        get(phy, "segment_duration_sec", 0.0),
        "physics.segment_duration_sec",
    )
    seg_dur > 0.0 ||
        error("[CONFIG] physics.segment_duration_sec must be > 0 (got $seg_dur).")
    batch_sz = checked_integer(get(phy, "batch_size", 0), "physics.batch_size")
    batch_sz >= 1 || error("[CONFIG] physics.batch_size must be ≥ 1 (got $batch_sz).")

    n_samples = sr * seg_dur
    n_samples >= 2.0 || error(
        "[CONFIG] sample_rate × segment_duration_sec = $n_samples < 2: FFT synthesis needs ≥ 2 samples per segment.",
    )
    if !isapprox(n_samples, round(n_samples); atol = 1e-9)
        @warn "[CONFIG] sample_rate × segment_duration_sec = $n_samples is not an integer; segment length is rounded to $(round(Int, n_samples)) samples."
    end

    data_source =
        checked_string(get(phy, "data_source", "synthetic"), "physics.data_source")
    if data_source == "external"
        ext =
            checked_string(get(phy, "external_data_path", ""), "physics.external_data_path")
        ext_path = isabspath(ext) ? ext : joinpath(PROJECT_ROOT, ext)
        isfile(ext_path) || error(
            "[CONFIG] physics.data_source = \"external\" but external_data_path not found: $ext_path",
        )
    elseif data_source != "synthetic"
        error(
            "[CONFIG] Unknown physics.data_source = \"$data_source\" (expected \"synthetic\" or \"external\").",
        )
    end

    # -- [telemetry] --
    haskey(tel, "session_start") || error("[CONFIG] telemetry.session_start is required.")
    try
        Time(tel["session_start"])
    catch
        error(
            "[CONFIG] telemetry.session_start is not a parseable time: $(tel["session_start"])",
        )
    end
    sess_h = checked_number(
        get(tel, "session_duration_hours", 0.0),
        "telemetry.session_duration_hours",
    )
    0.0 < sess_h <= 24.0 || error(
        "[CONFIG] telemetry.session_duration_hours must lie in (0, 24] (got $sess_h): the daily scheduler wraps Time arithmetic at 24 h.",
    )
    mbph = checked_number(
        get(tel, "max_batches_per_hour", 0.0),
        "telemetry.max_batches_per_hour",
    )
    mbph > 0.0 || error("[CONFIG] telemetry.max_batches_per_hour must be > 0 (got $mbph).")
    profile =
        checked_string(get(tel, "bandwidth_profile", "sine"), "telemetry.bandwidth_profile")
    mib = checked_integer(get(tel, "max_inflight_batches", 5), "telemetry.max_inflight_batches")
    mib >= 1 || error("[CONFIG] telemetry.max_inflight_batches must be ≥ 1 (got $mib).")
    mlf = checked_number(get(tel, "min_link_factor", 0.05), "telemetry.min_link_factor")
    0.0 <= mlf < 1.0 ||
        error("[CONFIG] telemetry.min_link_factor = $mlf outside [0, 1).")
    for (key, default) in (("sigmoid_steepness", 10.0), ("gaussian_sigma", 0.15))
        v = checked_number(get(tel, key, default), "telemetry.$key")
        v > 0.0 || error("[CONFIG] telemetry.$key must be > 0 (got $v).")
    end
    sip = checked_number(
        get(phy, "signal_injection_probability", 0.02),
        "physics.signal_injection_probability",
    )
    0.0 <= sip <= 1.0 ||
        error("[CONFIG] physics.signal_injection_probability = $sip outside [0, 1].")
    profile in ("sine", "sigmoid", "gaussian", "flat") ||
        @warn "[CONFIG] Unknown telemetry.bandwidth_profile = \"$profile\"; falling back to \"sine\"."

    # -- Real-time pacing sanity (loop-scheduler corner cases) --
    emitter_period_ms = seg_dur / speed_up * 1000.0
    if emitter_period_ms < 5.0
        @warn "[CONFIG] Emitter wall-clock period is $(round(emitter_period_ms, digits=2)) ms " *
              "(segment_duration_sec / speed_up). Below ~5 ms the generation loop cannot keep " *
              "pace with the accelerated clock and batch timestamps desynchronize. " *
              "Increase segment_duration_sec or decrease speed_up."
    end
    rx_slot_ms = 3600.0 / (mbph * speed_up) * 1000.0
    if rx_slot_ms < 2.0
        @warn "[CONFIG] Receiver download slot is $(round(rx_slot_ms, digits=2)) ms " *
              "(3600 / (max_batches_per_hour × speed_up)). The $(RECEIVER_SLEEP_FLOOR_SEC * 1000) ms sleep floor distorts " *
              "the effective downlink rate. Decrease speed_up or max_batches_per_hour."
    end

    # -- [packet_loss] --
    pl = get(cfg, "packet_loss", Dict{String,Any}())
    if get(pl, "enabled", false)
        model =
            lowercase(checked_string(get(pl, "model", "bernoulli"), "packet_loss.model"))
        model in ("bernoulli", "gilbert_elliott") || error(
            "[CONFIG] Unknown packet_loss.model = \"$model\" (expected \"bernoulli\" or \"gilbert_elliott\").",
        )
        for key in ("p_loss", "p_good_to_bad", "p_bad_to_good", "p_loss_good", "p_loss_bad")
            if haskey(pl, key)
                v = checked_number(pl[key], "packet_loss.$key")
                0.0 <= v <= 1.0 || error("[CONFIG] packet_loss.$key = $v outside [0, 1].")
            end
        end
        on_loss = lowercase(
            checked_string(get(pl, "on_loss", "retransmit"), "packet_loss.on_loss"),
        )
        on_loss in ("retransmit", "drop") || error(
            "[CONFIG] Unknown packet_loss.on_loss = \"$on_loss\" (expected \"retransmit\" or \"drop\").",
        )
        retries = checked_integer(get(pl, "max_retries", 3), "packet_loss.max_retries")
        retries >= 0 ||
            error("[CONFIG] packet_loss.max_retries must be ≥ 0 (got $retries).")
        if model == "gilbert_elliott" && Float64(get(pl, "p_bad_to_good", 0.0)) == 0.0
            @warn "[CONFIG] packet_loss.p_bad_to_good = 0: once the channel enters the BAD state it never recovers."
        end
        if model == "bernoulli" && Float64(get(pl, "p_loss", 0.05)) >= 1.0
            @warn "[CONFIG] packet_loss.p_loss = 1: every transfer fails; all batches will be dropped after max_retries."
        end
    end

    # -- [disruption] --
    haskey(cfg, "disaster") &&
        !haskey(cfg, "disruption") &&
        @warn "[CONFIG] The [disaster] section name is deprecated — rename it to [disruption]."
    d = get(cfg, "disruption", get(cfg, "disaster", Dict{String,Any}()))
    mission_days = test_dur * speed_up / 86_400.0
    event_windows = Tuple{Float64,Float64,Int}[] # (start_h, end_h incl. ramp, event index)
    for (i, e) in enumerate(get(d, "events", Any[]))
        start_day =
            checked_number(get(e, "start_day", -1.0), "disruption.events[$i].start_day")
        start_day >= 0.0 ||
            error("[CONFIG] disruption.events[$i].start_day must be ≥ 0 (got $start_day).")
        dur_h = checked_number(
            get(e, "duration_hours", 24.0),
            "disruption.events[$i].duration_hours",
        )
        dur_h > 0.0 ||
            error("[CONFIG] disruption.events[$i].duration_hours must be > 0 (got $dur_h).")
        rec_h = checked_number(
            get(e, "recovery_hours", 0.0),
            "disruption.events[$i].recovery_hours",
        )
        rec_h >= 0.0 ||
            error("[CONFIG] disruption.events[$i].recovery_hours must be ≥ 0 (got $rec_h).")
        sev = checked_number(get(e, "severity", 1.0), "disruption.events[$i].severity")
        0.0 <= sev <= 1.0 ||
            error("[CONFIG] disruption.events[$i].severity = $sev outside [0, 1].")
        if start_day >= mission_days
            # Inclusive boundary: an event at the exact final instant is
            # never simulated either.
            @warn "[CONFIG] disruption.events[$i] starts on mission day $start_day but the mission spans only $(round(mission_days, digits=2)) days: the event never fires."
        elseif sev >= 1.0 && start_day * 24.0 + dur_h >= mission_days * 24.0
            @warn "[CONFIG] disruption.events[$i] blacks out the link from day $start_day to mission end: no batch after the event onset will ever reach the ground."
        elseif start_day * 24.0 + dur_h + rec_h > mission_days * 24.0
            @warn "[CONFIG] disruption.events[$i] extends beyond mission end (blackout + recovery reach day $(round((start_day * 24.0 + dur_h + rec_h) / 24.0, digits=2)) of $(round(mission_days, digits=2))): the tail is truncated and never observed."
        end
        push!(event_windows, (start_day * 24.0, start_day * 24.0 + dur_h + rec_h, i))
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
        "bytes_per_sample",
        "bytes_batch_metadata",
        "bytes_event_row",
        "bytes_metrics_row",
        "bytes_mask_cell",
        "bytes_pointwise_cell",
        "bytes_plot",
        "bytes_log_per_batch",
    )
        if haskey(st, key)
            v = checked_number(st[key], "storage.$key")
            v > 0.0 || error("[CONFIG] storage.$key must be > 0 (got $v).")
        end
    end
    if haskey(st, "max_file_count")
        nf = checked_integer(st["max_file_count"], "storage.max_file_count")
        nf > 0 || error("[CONFIG] storage.max_file_count must be > 0 (got $nf).")
    end

    # -- [supervision] --
    sup = get(cfg, "supervision", Dict{String,Any}())
    if !isempty(sup)
        pol = lowercase(
            checked_string(
                get(sup, "on_component_failure", "abort"),
                "supervision.on_component_failure",
            ),
        )
        pol in ("abort", "continue", "restart") || error(
            "[CONFIG] Unknown supervision.on_component_failure = \"$pol\" (expected \"abort\", \"continue\", or \"restart\").",
        )
        nr = checked_integer(get(sup, "max_restarts", 3), "supervision.max_restarts")
        nr >= 0 || error("[CONFIG] supervision.max_restarts must be ≥ 0 (got $nr).")
        wd = checked_number(get(sup, "watchdog_sec", 30.0), "supervision.watchdog_sec")
        wd > 0.0 || error("[CONFIG] supervision.watchdog_sec must be > 0 (got $wd).")
    end

    # -- [retention] --
    ret = get(cfg, "retention", Dict{String,Any}())
    if !isempty(ret)
        en = get(ret, "enabled", false)
        en isa Bool ||
            error("[CONFIG] retention.enabled must be a boolean (got $(repr(en))).")
        for key in ("grace_hours", "high_watermark_gb", "log_rotate_mb")
            if haskey(ret, key)
                v = checked_number(ret[key], "retention.$key")
                v > 0.0 || error("[CONFIG] retention.$key must be > 0 (got $v).")
            end
        end
        if haskey(ret, "high_watermark_gb")
            budget = storage_budget(cfg)
            wm = Float64(ret["high_watermark_gb"])
            wm <= budget.max_gb || error(
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
    storage_budget(cfg::AbstractDict) -> (max_gb, max_files)

Resolves the run-directory disk budget [GB] and inode budget from `[storage]`.
`simulation.max_storage_gb` is honored as a deprecated fallback (with a
warning); with neither present the legacy default of 5.0 GB applies.
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
    return (max_gb = max_gb, max_files = max_files)
end

"""
    retention_settings(cfg::AbstractDict) -> NamedTuple

Parses the `[retention]` section into the custodian's operating parameters:
`enabled`, `grace_hours` (mission-time guarantee for delivered payloads),
`watermark_bytes` (prunable-payload size that triggers pruning; default 75 %
of the storage budget), and `log_rotate_bytes` (size-capped log rotation,
active regardless of `enabled`).
"""
function retention_settings(cfg::AbstractDict)
    ret = get(cfg, "retention", Dict{String,Any}())
    enabled = Bool(get(ret, "enabled", false))
    grace_hours = checked_number(get(ret, "grace_hours", 24.0), "retention.grace_hours")
    default_wm = 0.75 * storage_budget(cfg).max_gb
    watermark_gb = checked_number(
        get(ret, "high_watermark_gb", default_wm),
        "retention.high_watermark_gb",
    )
    rotate_mb = checked_number(get(ret, "log_rotate_mb", 64.0), "retention.log_rotate_mb")
    return (
        enabled = enabled,
        grace_hours = grace_hours,
        watermark_bytes = watermark_gb * 1024^3,
        log_rotate_bytes = rotate_mb * 1024^2,
    )
end

"""
    estimate_artifacts(cfg::AbstractDict) -> NamedTuple

Closed-form per-class artifact estimate for a run, computed entirely from the
configuration (upper bounds where exact counts depend on stochastic outcomes).
Classes: payload segment CSVs, batch metadata, event logs, metrics, the 2D
mask timeline, point-wise expansions, plots (session PNGs + summary; the
optional GIF is a manual post-processing product and is excluded), and text
logs. Calibration constants default to measured values and are overridable
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

    speed_up = Float64(sim["speed_up"])
    test_dur = Float64(sim["test_duration_sec"])
    seg_dur = Float64(phy["segment_duration_sec"])
    sr = Float64(phy["sample_rate"])
    batch_sz = Int(get(phy, "batch_size", 15))
    downtime_days = Float64(get(sim, "initial_downtime_days", 0.0))

    pl = get(cfg, "packet_loss", Dict{String,Any}())
    retries = get(pl, "enabled", false) ? Int(get(pl, "max_retries", 3)) : 0

    cal =
        key -> Float64(get(st, key, getproperty(STORAGE_CALIBRATION_DEFAULTS, Symbol(key))))

    sim_sec = test_dur * speed_up
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
    do_matrix = Bool(get(pp, "generate_batch_matrix", true))
    mask_bytes =
        do_matrix ? metrics_rows * (n_batches * cal("bytes_mask_cell") + 32.0) : 0.0

    do_expand = Bool(get(pp, "expand_to_pointwise_masks", false))
    target_rows = normalize_target_rows(get(pp, "target_event_rows", [-1]))
    # Branch on the concrete type: the union contract admits any Symbol, so a
    # type test narrows soundly where `=== :all` would not.
    n_expansions =
        do_expand ? (target_rows isa Vector{Int} ? length(target_rows) : metrics_rows) : 0
    pointwise_bytes = n_expansions * n_points * cal("bytes_pointwise_cell")

    plot_bytes = (mission_days + 1) * cal("bytes_plot")
    log_bytes = n_batches * cal("bytes_log_per_batch") + 200_000.0

    total_bytes =
        payload_bytes +
        batch_meta_bytes +
        event_bytes +
        metrics_bytes +
        mask_bytes +
        pointwise_bytes +
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
        (mission_days + 1) +
        2 +
        1 +
        2 +
        6 +
        8

    # Retention-prunable subset: delivered payload CSVs only. Batches that
    # terminally exhaust their retry budget land in lost/ (never prunable);
    # the expected terminal-loss fraction follows from the configured loss
    # model (per-attempt rate p_eff; retransmit → p_eff^(max_retries + 1),
    # drop → p_eff).
    p_eff = if !get(pl, "enabled", false)
        0.0
    elseif get(pl, "model", "bernoulli") == "gilbert_elliott"
        p_g2b = Float64(get(pl, "p_good_to_bad", 0.0))
        p_b2g = Float64(get(pl, "p_bad_to_good", 1.0))
        pi_bad = p_g2b + p_b2g > 0.0 ? p_g2b / (p_g2b + p_b2g) : 0.0
        pi_bad * Float64(get(pl, "p_loss_bad", 0.0)) +
        (1.0 - pi_bad) * Float64(get(pl, "p_loss_good", 0.0))
    else
        Float64(get(pl, "p_loss", 0.0))
    end
    lost_fraction = get(pl, "on_loss", "retransmit") == "drop" ? p_eff : p_eff^(retries + 1)
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
        mask_bytes = mask_bytes,
        pointwise_bytes = pointwise_bytes,
        plot_bytes = plot_bytes,
        log_bytes = log_bytes,
        total_bytes = total_bytes,
        file_count = file_count,
        prunable_bytes = payload_bytes * delivered_fraction,
        prunable_files = round(Int, n_segments * delivered_fraction),
    )
end

const STORAGE_CALIBRATION_DEFAULTS = (
    bytes_per_sample = 15.0,      # one Float32 CSV value + newline
    bytes_batch_metadata = 96.0,  # metadata.json
    bytes_event_row = 64.0,       # events_tx/rx.csv row
    bytes_metrics_row = 160.0,    # mission_profile.csv row
    bytes_mask_cell = 4.0,        # mask-timeline cell (digit + separator)
    bytes_pointwise_cell = 10.0,  # point-wise expansion row
    bytes_plot = 2.0e6,           # one PNG at px_per_unit = 4
    bytes_log_per_batch = 600.0,  # emitter+receiver log lines per batch
)

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

The same logic gates `storage.max_file_count`. Returns `nothing`; called
before any run directory is created.
"""
function check_storage_limits(cfg::AbstractDict)
    est = estimate_artifacts(cfg)
    budget = storage_budget(cfg)
    ret = retention_settings(cfg)
    gb = b -> round(b / 1024^3, digits = 4)

    @info "[STORAGE] Pre-run artifact estimate ($(est.n_segments) segments, $(est.n_batches) batches, $(est.mission_days) mission days):"
    @info "  -> Payload segment CSVs: $(gb(est.payload_bytes)) GB ($(est.n_points) samples)"
    @info "  -> Batch metadata:       $(gb(est.batch_meta_bytes)) GB"
    @info "  -> Event logs:           $(gb(est.event_bytes)) GB"
    @info "  -> Metrics profile:      $(gb(est.metrics_bytes)) GB (≤ $(est.metrics_rows) rows)"
    est.mask_bytes > 0 && @info "  -> Mask timeline:        $(gb(est.mask_bytes)) GB"
    est.pointwise_bytes > 0 &&
        @info "  -> Point-wise masks:     $(gb(est.pointwise_bytes)) GB"
    @info "  -> Plots:                $(gb(est.plot_bytes)) GB"
    @info "  -> Logs:                 $(gb(est.log_bytes)) GB"
    @info "  -> Total:                $(gb(est.total_bytes)) GB, ≈ $(est.file_count) files (budget: $(budget.max_gb) GB, $(budget.max_files) files)"

    max_bytes = budget.max_gb * 1024^3
    if !ret.enabled
        if est.total_bytes > max_bytes
            error(
                "[STORAGE] Estimated storage ($(gb(est.total_bytes)) GB) exceeds the configured budget ($(budget.max_gb) GB) and no mitigation is active. Enable [retention], reduce the mission span, or raise storage.max_storage_gb.",
            )
        elseif est.file_count > budget.max_files
            error(
                "[STORAGE] Estimated file count ($(est.file_count)) exceeds storage.max_file_count ($(budget.max_files)) and no mitigation is active. Enable [retention], reduce the mission span, or raise the budget.",
            )
        elseif est.total_bytes > 0.9 * max_bytes
            @warn "[STORAGE] Estimated storage ($(gb(est.total_bytes)) GB) is within 10 % of the configured budget ($(budget.max_gb) GB)."
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
            "[STORAGE] Even with retention active, the steady-state footprint ($(gb(steady_bytes)) GB: non-prunable classes + payload capped at the $(gb(ret.watermark_bytes)) GB watermark) exceeds the configured budget ($(budget.max_gb) GB). Reduce the mission span, lower retention.high_watermark_gb, or raise storage.max_storage_gb.",
        )
    elseif steady_files > budget.max_files
        error(
            "[STORAGE] Even with retention active, the steady-state file count ($steady_files) exceeds storage.max_file_count ($(budget.max_files)).",
        )
    end
    if est.total_bytes > max_bytes
        @warn "[STORAGE] Unbounded projection ($(gb(est.total_bytes)) GB) exceeds the budget ($(budget.max_gb) GB); retention bounds the steady state to ≈ $(gb(steady_bytes)) GB — proceeding."
    end
    grace_payload =
        est.payload_bytes / max(est.n_segments, 1) *
        (ret.grace_hours * 3600.0 / Float64(cfg["physics"]["segment_duration_sec"]))
    if grace_payload > ret.watermark_bytes
        @warn "[STORAGE] Payload generated within one retention.grace_hours window (≈ $(gb(grace_payload)) GB) exceeds retention.high_watermark_gb ($(gb(ret.watermark_bytes)) GB): the custodian cannot honor the grace guarantee and stay below the watermark; the watermark will be exceeded transiently."
    end
    @info "  -> Status: retention active — steady state ≈ $(gb(steady_bytes)) GB, ≈ $steady_files files"
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

A continuous 1D time-series array representing a specific chunk of physical observations.
"""
struct DataSegment
    id::Int
    timestamp::DateTime
    data::Vector{Float32}
    is_signal::Bool
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
    ground_archive::Int
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
        Ground_Archive = m.ground_archive,
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
`"gen"` (batch finalized onboard) and `"tx"` (batch placed on the downlink).
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
    return maximum(
        something(tryparse(Int, String(last(split(String(b), "_")))), 0) for b in df.Batch
    )
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

Generates a unique ID for the current simulation run using DrWatson's savename format.
"""
function generate_run_id()
    return DrWatson.savename(
        "RUN",
        Dict("t" => Dates.format(now(), "yyyymmdd_HHMMSS"), "pid" => getpid()),
    )
end

"""
    setup_run_dir(run_id::String; cfg=nothing)

Creates and returns the base directory for a simulation run along with its
required subdirectories. When the parsed configuration `cfg` is provided, a
`config_snapshot.toml` is written into the run directory (with `safesave`-style
backup rotation) so every run's exact parameters remain reproducible after
`config.toml` changes.
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
        snapshot_path = joinpath(base_dir, "config_snapshot.toml")
        backup_existing(snapshot_path)
        open(snapshot_path, "w") do io
            TOML.print(io, cfg)
        end
    end
    return base_dir
end

# --- Batch & Segment I/O ---
"""
    save_batch(path::String, batch::DataBatch)

Serializes a `DataBatch` and its metadata to the specified physical directory.
"""
function save_batch(path::String, batch::DataBatch)
    mkpath(path)
    metadata = Dict(
        "batch_id" => batch.id,
        "segment_count" => length(batch.segments),
        "created_at" => string(batch.created_at),
    )
    open(joinpath(path, "metadata.json"), "w") do io
        JSON3.write(io, metadata)
    end

    for seg in batch.segments
        save_segment(joinpath(path, "seg_$(seg.id).csv"), seg)
    end
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
    load_segment(path::String)

Loads a 1D CSV time series back into a `DataSegment` object.
"""
function load_segment(path::String)
    df = CSV.read(path, DataFrame)
    id_match = match(r"seg_(\d+)\.csv", basename(path))
    # The capture is a Union{Nothing, SubString}: guard the full chain so a
    # nonconforming filename degrades to id 0 instead of throwing.
    id = id_match !== nothing ? something(tryparse(Int, something(id_match[1], "")), 0) : 0
    return DataSegment(id, now(), Vector{Float32}(df.Amplitude), false)
end

# --- Visibility & Bandwidth ---
"""
    VisibilityModel

Maintains parameters for the DSN connectivity profile over a given planetary transit.
"""
struct VisibilityModel
    session_start::Time
    session_duration::Second
    profile::String
    sigmoid_steepness::Float64
    gaussian_sigma::Float64
end

# Backward-compatible constructor with the documented default profile shapes.
function VisibilityModel(session_start::Time, session_duration::Second, profile::String)
    return VisibilityModel(session_start, session_duration, profile, 10.0, 0.15)
end

"""
    is_visible(model::VisibilityModel, t::DateTime)

Evaluates whether the satellite currently has a line of sight to Earth.
Sessions crossing midnight (e.g. 20:00 start with an 8 hour duration) are
handled by testing the wrapped interval on both sides of the day boundary.
"""
function is_visible(model::VisibilityModel, t::DateTime)
    current_time = Time(t)
    session_end = model.session_start + model.session_duration # `Time` wraps at 24 h
    if model.session_start <= session_end
        return model.session_start <= current_time <= session_end
    else
        return current_time >= model.session_start || current_time <= session_end
    end
end

"""
    get_bandwidth_factor(model::VisibilityModel, t::DateTime)

Calculates the effective link capacity (0.0 to 1.0) based on the configured profile (sine, sigmoid, gaussian, flat).
"""
function get_bandwidth_factor(model::VisibilityModel, t::DateTime)
    if !is_visible(model, t)
        return 0.0
    end
    elapsed_ns = Time(t).instant.value - model.session_start.instant.value
    if elapsed_ns < 0 # session crossed midnight relative to `t`
        elapsed_ns += 24 * 3600 * 1_000_000_000
    end
    total_sec = model.session_duration.value
    progress = clamp(elapsed_ns / 1e9 / total_sec, 0.0, 1.0)

    if model.profile == "sine"
        return sin(pi * progress)^2
    elseif model.profile == "sigmoid"
        k = model.sigmoid_steepness
        return (tanh(k * progress) + tanh(k * (1 - progress))) / 2.0
    elseif model.profile == "gaussian"
        # centered at 0.5, stdev roughly 0.15
        return exp(-((progress - 0.5)^2) / (2 * model.gaussian_sigma^2))
    elseif model.profile == "flat"
        return 1.0
    else
        return sin(pi * progress)^2 # default fallback
    end
end

end # module TelemetryCore
