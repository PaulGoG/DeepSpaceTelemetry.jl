"""
    Supervisor

The mission orchestration layer: assembles a validated [`MissionPlan`](@ref)
from the configuration, runs the emitter and the receiver as supervised
tasks (abort / continue / restart policies, heartbeat watchdog, the
single-writer `component_events.csv`), keeps the lifecycle sentinels
consistent on every exit path, and drives the failure-isolated
post-processing stages. The headless entry point `scripts/run_full_sim.jl`
is argument parsing plus one call to [`run_mission`](@ref).
"""
module Supervisor

using ..TelemetryCore
using ..ChannelEffects
using ..VirtualInstrument
using ..Emitter
using ..Receiver
using ..Masks
using ..MissionFigures
using ..Export
using ..Publication
using CSV: CSV
using DataFrames: DataFrame
using Dates: Dates, DateTime, Millisecond, Second, now
using Logging: Logging, current_logger, with_logger
using LoggingExtras: TeeLogger
using SHA: sha256

# --- Component logging ---

"""
    CleanFileLogger(path::String, rotate_bytes::Int)

Component log sink: one line per record — `[Level] message`, with
structured keyword values on indented lines and exceptions rendered
compactly — without the `└ @ Module file:line` source-location suffix,
which is noise when the file is followed in a dashboard terminal. ANSI
escape sequences are stripped so the file reads cleanly after the run.
Records are appended per write (log rates are a few lines per batch), which
allows size-capped rotation to `name#k.log` (`retention.log_rotate_mb`)
without a held-open stream across the rotation boundary. Formatting never
throws: a throwing logger would terminate the task it logs for.
"""
struct CleanFileLogger <: Logging.AbstractLogger
    path::String
    rotate_bytes::Int
end

Logging.min_enabled_level(::CleanFileLogger) = Logging.Info
Logging.shouldlog(::CleanFileLogger, level, _module, group, id) = true
Logging.catch_exceptions(::CleanFileLogger) = true

"""
    strip_ansi(text::AbstractString) -> String

Removes ANSI escape sequences (colors, cursor motion) from a log message.
"""
strip_ansi(text::AbstractString) = replace(text, r"\e\[[0-9;]*[a-zA-Z]" => "")

"""
    render_log_value(v) -> String

Text of one structured log value for [`CleanFileLogger`](@ref): exceptions
(also the exception of an `(exception, backtrace)` tuple) through
`showerror`, everything else through `string`; a value whose rendering
throws yields a `<unprintable T>` placeholder, so the logger itself never
throws.
"""
function render_log_value(v)
    return try
        if v isa Exception
            sprint(showerror, v)
        elseif v isa Tuple && !isempty(v) && first(v) isa Exception
            sprint(showerror, first(v))
        else
            string(v)
        end
    catch
        "<unprintable $(typeof(v))>"
    end
end

function Logging.handle_message(
    logger::CleanFileLogger,
    level,
    message,
    _module,
    group,
    id,
    file,
    line;
    kwargs...,
)
    if isfile(logger.path) && filesize(logger.path) > logger.rotate_bytes
        TelemetryCore.backup_existing(logger.path)
    end
    text = message isa AbstractString ? strip_ansi(message) : string(message)
    open(logger.path, "a") do stream
        try
            println(stream, "[", level, "] ", text)
            for (k, v) in kwargs
                println(stream, "    ", k, " = ", render_log_value(v))
            end
        catch
            println(stream, "[Warn] <log record could not be formatted>")
        end
    end
    return nothing
end

# --- Mission plan ---

"""
    with_supervisor_log(f, run_dir::String, rotate_bytes::Int)

Runs `f()` with the current logger teed into `<run_dir>/supervisor.log`
([`CleanFileLogger`](@ref), rotated at `rotate_bytes`), so the
`[SUPERVISOR]`, `[POST]`, and `[CONFIG]` records of the mission and its
post-processing are on disk beside the component logs, where the console
output of a detached run is not. The file is truncated at entry.
"""
function with_supervisor_log(f, run_dir::String, rotate_bytes::Int)
    path = joinpath(run_dir, "supervisor.log")
    write(path, "")
    return with_logger(f, TeeLogger(current_logger(), CleanFileLogger(path, rotate_bytes)))
end

"""
    MissionPlan

Everything derived from a validated configuration before the mission clock
starts: the run ID, the `[simulation]` scalars, the typed `[telemetry]`,
`[physics]`, `[supervision]`, `[post_processing]`,
`[post_processing.publication]`, `[ground]`, `[dashboard]`, and `[contacts]`
settings, the composite link model, the
loss channel (seeded with `simulation.rng_seed`), the retry limit, and the
retention policy. Built by [`mission_plan`](@ref); nothing on disk depends
on it until [`run_mission`](@ref) creates the run directory.
"""
struct MissionPlan{
    T<:NamedTuple,
    P<:NamedTuple,
    S<:NamedTuple,
    L<:ChannelEffects.LossModel,
    PP<:NamedTuple,
    PB<:NamedTuple,
    G<:NamedTuple,
    D<:NamedTuple,
}
    cfg::Dict{String,Any}
    run_id::String
    speed_up::Float64
    start_sim::DateTime
    mission_wall_seconds::Float64
    initial_downtime_days::Float64
    telemetry::T
    physics::P
    supervision::S
    link::ChannelEffects.LinkModel
    loss_model::L
    max_retries::Int
    retention::TelemetryCore.RetentionPolicy
    markers::Vector{TelemetryCore.EventMarker}
    generation_gaps::Vector{Tuple{DateTime,DateTime}}
    onboard_capacity_batches::Int
    post_processing::PP
    publication::PB
    ground::G
    dashboard::D
    contacts::TelemetryCore.ContactsSettings
end

"""
    stamp_external_provenance!(cfg, physics, needed_days)

External-input coverage report and provenance stamp: row count and SHA-256
of the input file are computed up front — before any directory exists — so
exhaustion is predicted at startup rather than discovered mid-mission, and
the run snapshot pins the exact input consumed (no sidecar or generator
metadata is assumed). Writes `cfg["provenance"]`.
"""
function stamp_external_provenance!(
    cfg::AbstractDict,
    physics::NamedTuple,
    needed_days::Float64,
)
    path = physics.external_data_path
    resolved = isabspath(path) ? path : joinpath(TelemetryCore.PROJECT_ROOT, path)
    rows = max(countlines(resolved) - 1, 0) # header-inclusive count; ≈ for headerless files
    digest = open(io -> bytes2hex(sha256(io)), resolved)
    covered_days = rows / physics.sample_rate / 86_400.0
    if covered_days + 1e-9 < needed_days
        @warn "[INPUT] External data covers ≈ $(round(covered_days, digits=2)) of $(round(needed_days, digits=2)) mission days at the declared $(physics.sample_rate) Hz — the stream zero-pads from day $(round(covered_days, digits=2)) on."
    else
        @info "[INPUT] External data covers ≈ $(round(covered_days, digits=2)) mission days (mission needs $(round(needed_days, digits=2)))."
    end
    cfg["provenance"] = Dict{String,Any}(
        "external_data_path" => resolved,
        "external_data_rows" => rows,
        "external_data_sha256" => digest,
        "declared_sample_rate" => physics.sample_rate,
    )
    return cfg
end

"""
    mission_plan(cfg::Dict{String,Any}; run_id = "") -> MissionPlan

Validates `cfg` (safe intervals, then the storage budget), builds the
channel models — the loss channel, the run's only random stream, is seeded
with `simulation.rng_seed` — stamps external-input provenance when
`physics.data_source = "external"`, and fixes the run ID (generated when
empty). Writes nothing to disk and leaves `cfg` unmodified: the plan
carries a shallow copy of it, which is what receives the provenance stamp
and becomes the run's configuration snapshot.
"""
function mission_plan(cfg::Dict{String,Any}; run_id::AbstractString = "")
    TelemetryCore.validate_config(cfg)
    TelemetryCore.check_storage_limits(cfg)
    # Shallow copy: the provenance stamp below adds a top-level section and
    # must not surface in the caller's dictionary.
    cfg = Dict{String,Any}(cfg)
    sim = cfg["simulation"]
    speed_up = Float64(sim["speed_up"])
    start_sim = TelemetryCore.parsed_datetime(
        TelemetryCore.required_value(sim, "simulation", "start_sim_time"),
        "simulation.start_sim_time",
    )
    wall_seconds = TelemetryCore.mission_wall_seconds(cfg)
    downtime_days = Float64(get(sim, "initial_downtime_days", 0.0))
    seed = Int(get(sim, "rng_seed", 0))
    physics = TelemetryCore.physics_settings(cfg)
    if physics.data_source == "external"
        stamp_external_provenance!(
            cfg,
            physics,
            wall_seconds * speed_up / 86_400.0 + downtime_days,
        )
    end
    return MissionPlan(
        cfg,
        isempty(run_id) ? TelemetryCore.generate_run_id(cfg) : String(run_id),
        speed_up,
        start_sim,
        wall_seconds,
        downtime_days,
        TelemetryCore.telemetry_settings(cfg),
        physics,
        TelemetryCore.supervision_settings(cfg),
        ChannelEffects.build_link_model(cfg),
        ChannelEffects.build_loss_model(cfg, seed),
        ChannelEffects.loss_retry_limit(cfg),
        TelemetryCore.retention_settings(cfg),
        TelemetryCore.event_marker_settings(cfg),
        ChannelEffects.generation_gaps(cfg, start_sim),
        TelemetryCore.onboard_capacity(cfg).batches,
        TelemetryCore.post_processing_settings(cfg),
        TelemetryCore.publication_settings(cfg),
        TelemetryCore.ground_settings(cfg),
        TelemetryCore.dashboard_settings(cfg),
        TelemetryCore.contacts_settings(cfg),
    )
end

# --- Supervision ---

"""
    record_generation_gap!(run_dir, clock)

Bounds an emitter outage in `events_tx.csv`: a `gap_start` row at the last
recorded generation instant and a `gap_end` row at the current mission
time (Batch = `STREAM`). Called before a replacement emitter is spawned —
no live `events_tx` writer exists at that instant.
"""
function record_generation_gap!(run_dir::String, clock::TelemetryCore.SimulationClock)
    tx_log_path = joinpath(run_dir, "events_tx.csv")
    last_gen =
        isfile(tx_log_path) ?
        maximum(CSV.read(tx_log_path, DataFrame).SimTime; init = clock.start_sim_time) :
        clock.start_sim_time
    TelemetryCore.log_tx_event(run_dir, last_gen, "STREAM", "gap_start")
    TelemetryCore.log_tx_event(
        run_dir,
        TelemetryCore.get_current_sim_time(clock),
        "STREAM",
        "gap_end",
    )
    return nothing
end

"""
    log_component_event!(run_dir, clock, component, event)

Appends one row to the single-writer `component_events.csv`
(`SimTime,Component,Event`; events `down`, `restart`, `stalled`,
`recovered`).
"""
function log_component_event!(
    run_dir::String,
    clock::TelemetryCore.SimulationClock,
    component::Symbol,
    event::String,
)
    path = joinpath(run_dir, "component_events.csv")
    header = !isfile(path)
    open(path, "a") do io
        header && println(io, "SimTime,Component,Event")
        println(io, TelemetryCore.get_current_sim_time(clock), ",", component, ",", event)
    end
    return nothing
end

"""
    supervise!(spawners, run_dir, clock, stop_flag, heartbeats, policy;
               on_restart = (name, attempt) -> nothing,
               poll_sec = TelemetryCore.RECEIVER_POLL_INTERVAL_SEC) -> Dict{Symbol,Int}

Runs the components until all of them have finished. `spawners[name](attempt)`
returns the component's `Task` (attempt 0 is the primary launch, attempt
≥ 1 a supervised restart). On a failed task the policy
(`policy.on_component_failure`) decides: `"abort"` raises `stop_flag` so the
partner stops cooperatively, `"continue"` leaves the partner running
one-sided, `"restart"` relaunches up to `policy.max_restarts` times after
calling `on_restart(name, attempt)`. A component whose heartbeat file in
`heartbeats` stays untouched for longer than `policy.watchdog_sec` is
recorded as `stalled` (and `recovered` when it resumes); the watchdog only
records, it never intervenes. Every lifecycle transition is appended to
`component_events.csv`, and failures, policy decisions, restarts, and
watchdog trips are reported as `[SUPERVISOR]` log records through the
logger active in the calling task (the global logger under
[`run_mission`](@ref); the component tasks log to their own files).
Returns the restart count per component.
"""
function supervise!(
    spawners::Dict{Symbol,<:Function},
    run_dir::String,
    clock::TelemetryCore.SimulationClock,
    stop_flag::Threads.Atomic{Bool},
    heartbeats::Dict{Symbol,String},
    policy::NamedTuple;
    on_restart::Function = (name, attempt) -> nothing,
    poll_sec::Float64 = TelemetryCore.RECEIVER_POLL_INTERVAL_SEC,
)
    tasks = Dict{Symbol,Task}(name => spawn(0) for (name, spawn) in spawners)
    restart_counts = Dict{Symbol,Int}(name => 0 for name in keys(spawners))
    failure_handled = Set{Symbol}()
    watchdog_tripped = Set{Symbol}()
    while !all(istaskdone, values(tasks))
        sleep(poll_sec)
        for (name, t) in collect(tasks)
            (istaskfailed(t) && !(name in failure_handled)) || continue
            stack = current_exceptions(t)
            failure =
                isempty(stack) ? t.result : (stack[end].exception, stack[end].backtrace)
            @error "[SUPERVISOR] Component $name failed." exception = failure
            log_component_event!(run_dir, clock, name, "down")
            if policy.on_component_failure == "restart" &&
               restart_counts[name] < policy.max_restarts
                restart_counts[name] += 1
                on_restart(name, restart_counts[name])
                tasks[name] = spawners[name](restart_counts[name])
                log_component_event!(run_dir, clock, name, "restart")
                @warn "[SUPERVISOR] Restarted $name (attempt $(restart_counts[name]) of $(policy.max_restarts))."
            elseif policy.on_component_failure == "continue"
                push!(failure_handled, name)
                @warn "[SUPERVISOR] Policy continue: $name stays down."
            else
                push!(failure_handled, name)
                stop_flag[] = true
                @error "[SUPERVISOR] Policy abort: stopping the partner component."
            end
        end
        # Watchdog: a hung (not dead) component stops heartbeating.
        for (name, heartbeat_file) in heartbeats
            t = get(tasks, name, nothing)
            (t === nothing || istaskdone(t) || !isfile(heartbeat_file)) && continue
            stalled = time() - mtime(heartbeat_file) > policy.watchdog_sec
            if stalled && !(name in watchdog_tripped)
                push!(watchdog_tripped, name)
                log_component_event!(run_dir, clock, name, "stalled")
                @warn "[SUPERVISOR] Watchdog: no heartbeat from $name for > $(policy.watchdog_sec) s."
            elseif !stalled && name in watchdog_tripped
                delete!(watchdog_tripped, name)
                log_component_event!(run_dir, clock, name, "recovered")
            end
        end
    end
    for t in values(tasks)
        try
            wait(t)
        catch e
            # A failed task was already reported above; anything else is
            # the supervisor's own fault and propagates.
            e isa TaskFailedException || rethrow()
        end
    end
    return restart_counts
end

"""
    build_instrument(physics::NamedTuple, start_t::DateTime, markers) -> VirtualInstrument.InstrumentState

The payload instrument of `[physics]` anchored at `start_t`: the start of
the initial blind spot for the pre-population ([`Emitter.instrument_epoch`](@ref)),
the current mission time for a restarted emitter.
"""
function build_instrument(
    physics::NamedTuple,
    start_t::DateTime,
    markers::Vector{TelemetryCore.EventMarker},
)
    return VirtualInstrument.InstrumentState(
        start_t,
        physics.sample_rate,
        physics.segment_duration_sec,
        physics.data_source,
        physics.external_data_path;
        markers = markers,
    )
end

"""
    component_spawners(plan, run_dir, clock, deadline, stop_flag, heartbeats,
                       instrument, pending_segments, emitter_logger,
                       receiver_logger, orig_stdout) -> Dict{Symbol,Function}

The emitter and receiver launchers consumed by [`supervise!`](@ref).
Attempt 0 continues the pre-populated instrument and partial batch; a
restarted emitter (attempt ≥ 1) takes a fresh instrument anchored at the
current mission time — a genuine generation gap — and no carried-over
partial batch.
"""
function component_spawners(
    plan::MissionPlan,
    run_dir::String,
    clock::TelemetryCore.SimulationClock,
    deadline::DateTime,
    stop_flag::Threads.Atomic{Bool},
    heartbeats::Dict{Symbol,String},
    instrument::VirtualInstrument.InstrumentState,
    pending_segments::Vector{TelemetryCore.DataSegment},
    emitter_logger::CleanFileLogger,
    receiver_logger::CleanFileLogger,
    orig_stdout::IO,
)
    physics = plan.physics
    telemetry = plan.telemetry
    dashboard = plan.dashboard
    run_emitter_logged(attempt::Int) = with_logger(emitter_logger) do
        Emitter.run_emitter(
            clock,
            plan.link,
            plan.run_id,
            attempt == 0 ? instrument :
            build_instrument(
                physics,
                TelemetryCore.get_current_sim_time(clock),
                plan.markers,
            );
            batch_size = physics.batch_size,
            pending_segments = attempt == 0 ? pending_segments :
                               TelemetryCore.DataSegment[],
            markers = plan.markers,
            generation_gaps = plan.generation_gaps,
            onboard_capacity_batches = plan.onboard_capacity_batches,
            max_inflight_batches = telemetry.max_inflight_batches,
            deadline = deadline,
            stop = stop_flag,
            heartbeat_path = heartbeats[:emitter],
        )
    end
    run_receiver_logged(attempt::Int) = with_logger(receiver_logger) do
        Receiver.run_receiver(
            clock,
            plan.link,
            plan.run_id;
            orig_stdout = orig_stdout,
            status_panel = dashboard.receiver_status_panel,
            batch_transfer_sec = telemetry.nominal_batch_transfer_sec,
            loss_model = plan.loss_model,
            max_retries = plan.max_retries,
            retention = plan.retention,
            min_link_factor = telemetry.min_link_factor,
            round_trip_light_time_sec = telemetry.round_trip_light_time_sec,
            deadline = deadline,
            stop = stop_flag,
            heartbeat_path = heartbeats[:receiver],
        )
    end
    return Dict{Symbol,Function}(
        :emitter => attempt -> Threads.@spawn(run_emitter_logged(attempt)),
        :receiver => attempt -> Threads.@spawn(run_receiver_logged(attempt)),
    )
end

# --- Post-processing ---

"""
    post_process!(plan, run_dir; orig_stdout = stdout)

The derived products after both components have finished: the mission
summary and session figures ([`MissionFigures.generate_mission_plots`](@ref)),
the 2D batch-state timeline (`post_processing.generate_mask_timeline`), the
flagged figure products of [`TelemetryCore.FIGURE_PRODUCTS`](@ref) (alert
latency, delivery delay, batch-state raster, in that order), the point-wise
0/1 expansions (`expand_to_pointwise_masks`, rows from `target_event_rows`),
the HDF5 product export (`hdf5_export`), and the publication figure export
(`[post_processing.publication]`). Each stage is failure-isolated: the
simulation data is already on disk, so an error is reported loudly but never
aborts the remaining stages (every product can be regenerated by the
standalone post-processing scripts).
"""
function post_process!(plan::MissionPlan, run_dir::String; orig_stdout::IO = stdout)
    post_processing = plan.post_processing
    println(orig_stdout, "\nRendering the mission and session figures")
    try
        MissionFigures.generate_mission_plots(run_dir)
    catch e
        @error "[POST] Mission figure rendering failed — run data is intact; re-call MissionFigures.generate_mission_plots(run_dir)." exception =
            (e, catch_backtrace())
    end
    if post_processing.generate_mask_timeline
        println(orig_stdout, "\nGenerating the post-processing telemetry masks")
        try
            Masks.generate_telemetry_masks(run_dir)
        catch e
            @error "[POST] Mask-matrix generation failed — run data is intact." exception =
                (e, catch_backtrace())
        end
    end
    for product in TelemetryCore.FIGURE_PRODUCTS
        getproperty(post_processing.figures, product.flag) || continue
        println(orig_stdout, "\n", product.announcement)
        try
            TelemetryCore.render_figure_product(
                Val(product.flag),
                run_dir,
                post_processing,
                plan.ground,
            )
        catch e
            @error "[POST] $(product.title) failed — run data is intact." exception =
                (e, catch_backtrace())
        end
    end
    post_processing.expand_to_pointwise_masks &&
        expand_pointwise_masks!(plan, run_dir, orig_stdout)
    if post_processing.hdf5_export
        println(orig_stdout, "\nExporting the run products to HDF5")
        try
            Export.export_hdf5(run_dir)
        catch e
            @error "[POST] HDF5 export failed — run data is intact." exception =
                (e, catch_backtrace())
        end
    end
    publication = plan.publication
    if publication.enabled
        println(orig_stdout, "\nExporting the publication figures")
        try
            Publication.export_publication_figures(
                run_dir;
                format = publication.format,
                column_width_mm = publication.column_width_mm,
                export_dir = publication.export_dir,
            )
        catch e
            @error "[POST] Publication export failed — run data is intact." exception =
                (e, catch_backtrace())
        end
    end
    return nothing
end

"""
    expand_pointwise_masks!(plan::MissionPlan, run_dir::String, orig_stdout::IO)

The point-wise expansion stage of [`post_process!`](@ref): every row of
`post_processing.target_event_rows` (`"all"`, integers, `-1` = last, range
strings) expanded by [`Masks.expand_pointwise_mask`](@ref), each row
failure-isolated.
"""
function expand_pointwise_masks!(plan::MissionPlan, run_dir::String, orig_stdout::IO)
    println(orig_stdout, "\nExpanding the telemetry masks to point-wise 0/1 arrays")
    try
        physics = plan.physics
        total_sim_sec =
            plan.mission_wall_seconds * plan.speed_up +
            plan.initial_downtime_days * 86_400.0
        total_segments = ceil(Int, total_sim_sec / physics.segment_duration_sec)
        total_points =
            round(Int, total_segments * physics.segment_duration_sec * physics.sample_rate)
        rows_spec = plan.post_processing.target_event_rows
        target_rows =
            rows_spec isa Symbol ? collect(1:TelemetryCore.mask_timeline_rows(run_dir)) :
            rows_spec
        for row_idx in target_rows
            out_name =
                row_idx == -1 ? "pointwise_mask_final.csv" :
                "pointwise_mask_t$(row_idx).csv"
            try
                Masks.expand_pointwise_mask(
                    run_dir,
                    total_points,
                    row_idx,
                    joinpath(run_dir, "masks", out_name),
                )
            catch e
                @error "[POST] Point-wise expansion failed for row $row_idx — continuing with the remaining rows." exception =
                    (e, catch_backtrace())
            end
        end
    catch e
        @error "[POST] Point-wise mask expansion stage failed — run data is intact." exception =
            (e, catch_backtrace())
    end
    return nothing
end

# --- Mission ---

"""
    contact_summary(plan::MissionPlan) -> String

One-line description of the contact schedule for the mission banner: the
daily window with its seasonal extension and exception count, or the
explicit pass count, plus the low-latency periods and whether they are
enabled.
"""
function contact_summary(plan::MissionPlan)
    contacts = plan.contacts
    line = if !isempty(contacts.passes)
        "explicit schedule, $(length(contacts.passes)) passes"
    else
        start = Dates.format(plan.telemetry.session_start, "HH:MM")
        hours = round(plan.telemetry.session_duration.value / 3600, digits = 1)
        seasonal =
            contacts.seasonal_extension_hours > 0 ?
            ", seasonal extension up to $(contacts.seasonal_extension_hours) h" : ""
        exceptions =
            isempty(contacts.exceptions) ? "" :
            ", $(length(contacts.exceptions)) exception(s)"
        "daily window $start + $hours h$seasonal$exceptions"
    end
    n_periods = length(contacts.low_latency_periods)
    n_periods == 0 && return line
    return line *
           "; $n_periods low-latency period(s)" *
           (contacts.low_latency_enabled ? "" : " disabled")
end

"""
    print_banner(io::IO, plan::MissionPlan, run_dir::String)

Writes the mission-start banner to `io`: run ID, mission span and speed-up,
link capacity and the daily capacity balance, the contact schedule
([`contact_summary`](@ref)), markers, generation gaps, the on-board
recorder ceiling, and the log location.
"""
function print_banner(io::IO, plan::MissionPlan, run_dir::String)
    println(io, "="^55)
    println(io, lpad("DEEP-SPACE TELEMETRY MISSION START", 44))
    println(io, "="^55)
    println(io, rpad("Run ID:", 20), plan.run_id)
    println(
        io,
        rpad("Mission span:", 20),
        "$(plan.mission_wall_seconds) wall-clock seconds",
    )
    println(io, rpad("Speed-up:", 20), "$(plan.speed_up)x")
    link_line =
        isnan(plan.telemetry.catch_up_ratio) ?
        "$(round(plan.telemetry.max_batches_per_hour, digits = 1)) batches/h at full capacity" :
        "catch-up ratio $(round(plan.telemetry.catch_up_ratio, digits = 2)) (downlink over production), " *
        "$(round(plan.telemetry.max_batches_per_hour, digits = 1)) batches/h at full capacity"
    println(io, rpad("Link:", 20), link_line)
    balance = TelemetryCore.capacity_balance(plan.cfg)
    println(
        io,
        rpad("Capacity:", 20),
        "profile mean $(round(balance.profile_mean, digits = 2)) ($(plan.telemetry.bandwidth_profile)); " *
        "$(round(Int, balance.capacity_per_pass)) batches per $(balance.pass_hours) h nominal pass, " *
        "$(round(Int, balance.produced_per_day)) produced per day",
    )
    println(io, rpad("Contacts:", 20), contact_summary(plan))
    isempty(plan.markers) || println(
        io,
        rpad("Markers:", 20),
        join(("$(m.label) at $(m.time)" for m in plan.markers), "; "),
    )
    isempty(plan.generation_gaps) || println(
        io,
        rpad("Generation gaps:", 20),
        join(("$g0 – $g1" for (g0, g1) in plan.generation_gaps), "; "),
    )
    capacity = TelemetryCore.onboard_capacity(plan.cfg)
    println(
        io,
        rpad("Recorder:", 20),
        "$(capacity.days) days of production = $(capacity.batches) batches" *
        (isnan(capacity.gigabit) ? "" : " ≈ $(round(capacity.gigabit, digits = 1)) Gbit"),
    )
    println(io, rpad("Logs:", 20), "$run_dir/*.log")
    println(io, "="^55)
    return nothing
end

"""
    warm_up_components!(plan, orig_stdout)

Compiles both component loops before the mission clock starts: each is
entered once with a deadline already in the past against a scratch run
directory (`<run_id>__warmup`, removed afterwards), with the same argument
types the mission uses. Without this, the first-call compilation of the
loops — several wall-clock seconds in a fresh process — would elapse as
mission time after the anchor (hours at high `speed_up`; a short mission
could expire before either component ran). Returns the warm-up duration
[s].
"""
function warm_up_components!(plan::MissionPlan, orig_stdout::IO)
    t0 = time()
    warm_id = plan.run_id * "__warmup"
    warm_dir = TelemetryCore.run_directory(warm_id)
    mkpath(warm_dir)
    try
        logger = CleanFileLogger(
            joinpath(warm_dir, "warmup.log"),
            plan.retention.log_rotate_bytes,
        )
        clock = TelemetryCore.SimulationClock(now(), plan.start_sim, plan.speed_up)
        past = now() - Second(1)
        stop_flag = Threads.Atomic{Bool}(false)
        physics = plan.physics
        with_logger(logger) do
            Emitter.run_emitter(
                clock,
                plan.link,
                warm_id,
                build_instrument(physics, plan.start_sim, plan.markers);
                batch_size = physics.batch_size,
                max_inflight_batches = plan.telemetry.max_inflight_batches,
                deadline = past,
                stop = stop_flag,
                heartbeat_path = joinpath(warm_dir, "emitter_alive"),
            )
            Receiver.run_receiver(
                clock,
                plan.link,
                warm_id;
                orig_stdout = orig_stdout,
                status_panel = plan.dashboard.receiver_status_panel,
                batch_transfer_sec = plan.telemetry.nominal_batch_transfer_sec,
                loss_model = plan.loss_model,
                max_retries = plan.max_retries,
                retention = plan.retention,
                min_link_factor = plan.telemetry.min_link_factor,
                round_trip_light_time_sec = plan.telemetry.round_trip_light_time_sec,
                deadline = past,
                stop = stop_flag,
                heartbeat_path = joinpath(warm_dir, "receiver_alive"),
            )
        end
    finally
        rm(warm_dir; recursive = true, force = true)
    end
    return time() - t0
end

"""
    execute_mission!(plan, run_dir, orig_stdout)

The mission proper inside an existing run directory: fresh component logs,
sequential pre-population of the onboard buffer, the component warm-up
([`warm_up_components!`](@ref)), the mission clock with its persisted
anchor and absolute deadline, the supervised component tasks, and the
post-processing stages. Called by [`run_mission`](@ref), which owns the
lifecycle sentinels.
"""
function execute_mission!(plan::MissionPlan, run_dir::String, orig_stdout::IO)
    emitter_log = joinpath(run_dir, "emitter.log")
    receiver_log = joinpath(run_dir, "receiver.log")
    write(emitter_log, "")
    write(receiver_log, "") # fresh logs for this run
    rotate_bytes = plan.retention.log_rotate_bytes
    emitter_logger = CleanFileLogger(emitter_log, rotate_bytes)
    receiver_logger = CleanFileLogger(receiver_log, rotate_bytes)
    physics = plan.physics

    # Pre-populate the onboard buffer sequentially before the clock starts;
    # the returned instrument and partial batch continue into the main loop.
    println(
        orig_stdout,
        "Pre-populating the onboard buffer for $(plan.initial_downtime_days) days",
    )
    instrument, pending_segments = with_logger(emitter_logger) do
        Emitter.pre_populate(
            build_instrument(
                physics,
                Emitter.instrument_epoch(plan.start_sim, plan.initial_downtime_days),
                plan.markers,
            ),
            plan.start_sim,
            plan.run_id;
            batch_size = physics.batch_size,
            markers = plan.markers,
            generation_gaps = plan.generation_gaps,
            onboard_capacity_batches = plan.onboard_capacity_batches,
        )
    end

    # Component loops compiled before the clock anchor: compilation must
    # not elapse as mission time.
    warm_up_sec = warm_up_components!(plan, orig_stdout)
    println(
        orig_stdout,
        "Component warm-up (compilation): $(round(warm_up_sec, digits = 1)) s",
    )

    # Shared absolute deadline + persisted anchor: both loops terminate at
    # the same wall instant, and a re-attaching component reconstructs the
    # identical mission clock (component outages elapse as mission time).
    clock = TelemetryCore.SimulationClock(now(), plan.start_sim, plan.speed_up)
    deadline =
        clock.start_real_time + Millisecond(round(Int, plan.mission_wall_seconds * 1000))
    TelemetryCore.save_clock_anchor(run_dir, clock, deadline)
    TelemetryCore.save_markers(run_dir, plan.markers)

    stop_flag = Threads.Atomic{Bool}(false)
    heartbeats = Dict{Symbol,String}(
        :emitter => joinpath(run_dir, "emitter_alive"),
        :receiver => joinpath(run_dir, "receiver_alive"),
    )
    print_banner(orig_stdout, plan, run_dir)

    spawners = component_spawners(
        plan,
        run_dir,
        clock,
        deadline,
        stop_flag,
        heartbeats,
        instrument,
        pending_segments,
        emitter_logger,
        receiver_logger,
        orig_stdout,
    )
    supervise!(
        spawners,
        run_dir,
        clock,
        stop_flag,
        heartbeats,
        plan.supervision;
        on_restart = (name, _) ->
            name == :emitter && record_generation_gap!(run_dir, clock),
    )
    rm(joinpath(run_dir, "HALT"), force = true) # consumed if an operator halted the run

    post_process!(plan, run_dir; orig_stdout = orig_stdout)
    println(orig_stdout, "\n=== MISSION COMPLETE ===")
    println(orig_stdout, "Results saved in: $run_dir")
    println(orig_stdout, "Summary plots available in: $(joinpath(run_dir, "plots"))")
    return nothing
end

"""
    run_mission(cfg::Dict{String,Any}; run_id = "", orig_stdout = stdout) -> String

The headless pipeline end to end: single-thread advisory, [`mission_plan`](@ref)
(validation, storage gate, models, provenance), the run directory with its
configuration snapshot, the lifecycle sentinels — `RUN_ACTIVE` while the
pipeline may still write, then `RUN_COMPLETE` at lifecycle end (not
success: a failed component still reaches it after the failure-isolated
post-processing) or `RUN_ABORTED` on any escaping exception — and
[`execute_mission!`](@ref) under [`with_supervisor_log`](@ref). Returns the
run directory.
"""
function run_mission(
    cfg::Dict{String,Any};
    run_id::AbstractString = "",
    orig_stdout::IO = stdout,
)
    advisory = TelemetryCore.thread_advisory()
    advisory === nothing || @warn advisory
    plan = mission_plan(cfg; run_id = run_id)
    run_dir = TelemetryCore.setup_run_dir(plan.run_id; cfg = plan.cfg)
    rm(joinpath(run_dir, "RUN_COMPLETE"), force = true)
    touch(joinpath(run_dir, "RUN_ACTIVE"))
    completed = false
    try
        with_supervisor_log(run_dir, plan.retention.log_rotate_bytes) do
            execute_mission!(plan, run_dir, orig_stdout)
        end
        completed = true
    finally
        # Sentinels consistent on every exit path: an abort before lifecycle
        # end must not strand RUN_ACTIVE (a consumer would see a live run
        # with no process).
        rm(joinpath(run_dir, "RUN_ACTIVE"), force = true)
        touch(joinpath(run_dir, completed ? "RUN_COMPLETE" : "RUN_ABORTED"))
    end
    return run_dir
end

end # module Supervisor
