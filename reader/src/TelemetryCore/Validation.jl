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
  - the retired keys of `REMOVED_CONFIG_KEYS`, rejected with the
    replacement named (in 3.0: the point-wise mask keys,
    `supervision.watchdog_sec`, the `storage.bytes_*` calibration, and
    `storage.onboard_capacity_days`, now `telemetry.onboard_capacity_days`)

Warnings:
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
            joinpath(PROJECT_ROOT[], physics.external_data_path)
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
    for key in ("max_storage_gb", "max_ram_gb")
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
