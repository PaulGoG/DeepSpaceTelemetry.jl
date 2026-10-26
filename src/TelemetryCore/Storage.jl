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
