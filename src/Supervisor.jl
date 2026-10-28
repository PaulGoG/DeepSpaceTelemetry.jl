"""
    Supervisor

The mission orchestration layer: assembles a validated [`MissionPlan`](@ref)
from the configuration, runs the emitter and the receiver as supervised
tasks on the tick driver (abort / continue / restart policies, the
single-writer `component_events.csv`), keeps the lifecycle sentinels
consistent on every exit path, and drives the failure-isolated
post-processing stages. The headless entry point `scripts/run_full_sim.jl`
is argument parsing plus one call to [`run_mission`](@ref).
"""
module Supervisor

using ..TelemetryCore: TelemetryCore
using ..ChannelEffects
using ..VirtualInstrument
using ..Emitter
using ..Receiver
using ..Masks
using ..MissionFigures
using ..Metrology
using ..Export
using ..Publication
using DataFrames: DataFrame
using Dates: Dates, DateTime, Millisecond, now
using Logging: Logging, current_logger, with_logger
using LoggingExtras: TeeLogger
using SHA: sha256

# --- Component logging ---

"""
    CleanFileLogger(path::String, rotate_bytes::Int)

Component log sink: one `[Level] message` line per record, structured
keyword values on indented lines, exceptions rendered compactly, and no
`└ @ Module file:line` source-location suffix, which is noise when the file
is followed in a dashboard terminal. ANSI escape sequences are stripped so
the file reads cleanly after the run. Each record is appended with its own
open (log rates are a few lines per batch), which allows size-capped
rotation to `name#k.log` (`retention.log_rotate_mb`) without a stream held
open across the rotation boundary. Neither formatting nor file I/O throws,
as a throwing logger would terminate the task it logs for: a record whose
rotation or write fails is dropped with a line on `stderr`.
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
    text = message isa AbstractString ? strip_ansi(message) : string(message)
    try
        if isfile(logger.path) && filesize(logger.path) > logger.rotate_bytes
            TelemetryCore.backup_existing(logger.path)
        end
        open(logger.path, "a") do stream
            try
                println(stream, "[", level, "] ", text)
                for (k, v) in kwargs
                    println(stream, "    ", k, " = ", render_log_value(v))
                end
            catch e
                e isa Union{Base.IOError,SystemError} && rethrow()
                println(stream, "[Warn] <log record could not be formatted>")
            end
        end
    catch e
        # The record is lost, not the component: report on stderr.
        e isa Union{Base.IOError,SystemError} || rethrow()
        println(stderr, "[CleanFileLogger] $(logger.path): ", sprint(showerror, e))
    end
    return nothing
end

# --- Mission plan ---

"""
    with_supervisor_log(f, run_dir::String, rotate_bytes::Int; append::Bool = false)

Runs `f()` with the current logger teed into `<run_dir>/supervisor.log`
([`CleanFileLogger`](@ref), rotated at `rotate_bytes`), so the
`[SUPERVISOR]`, `[POST]`, and `[CONFIG]` records of the mission and its
post-processing are on disk beside the component logs, where the console
output of a detached run is not. The file is truncated at entry unless
`append` is set, in which case the new records follow the existing ones.
"""
function with_supervisor_log(f, run_dir::String, rotate_bytes::Int; append::Bool = false)
    path = joinpath(run_dir, "supervisor.log")
    append || write(path, "")
    return with_logger(f, TeeLogger(current_logger(), CleanFileLogger(path, rotate_bytes)))
end

"""
    MissionPlan

Everything derived from a validated configuration before the mission clock
starts: the run ID, the `[simulation]` scalars, the payload origin
([`Emitter.instrument_epoch`](@ref)), the typed `[telemetry]`,
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
    mode::String
    mission_days::Float64
    initial_downtime_days::Float64
    payload_origin::DateTime
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

Adds `external_data_path`, `external_data_rows`, `external_data_sha256`,
`declared_sample_rate`, and `external_data_columns` (the names of the
payload columns, `["Amplitude"]` when `physics.external_data_columns` is
empty) to `cfg["provenance"]`, and logs whether the input covers
`needed_days`. Row count and SHA-256 are computed before any directory
exists, so exhaustion is predicted at startup rather than discovered
mid-mission, and the run snapshot pins the exact input consumed without
assuming sidecar or generator metadata.
"""
function stamp_external_provenance!(
    cfg::AbstractDict,
    physics::NamedTuple,
    needed_days::Float64,
)
    path = physics.external_data_path
    resolved = isabspath(path) ? path : joinpath(TelemetryCore.PROJECT_ROOT[], path)
    rows = max(countlines(resolved) - 1, 0) # header-inclusive count; ≈ for headerless files
    digest = open(io -> bytes2hex(sha256(io)), resolved)
    covered_days = rows / physics.sample_rate / 86_400.0
    if covered_days + 1e-9 < needed_days
        @warn "[INPUT] External data covers ≈ $(round(covered_days, digits=2)) of $(round(needed_days, digits=2)) mission days at the declared $(physics.sample_rate) Hz — the stream zero-pads from day $(round(covered_days, digits=2)) on."
    else
        @info "[INPUT] External data covers ≈ $(round(covered_days, digits=2)) mission days (mission needs $(round(needed_days, digits=2)))."
    end
    merge!(
        get!(Dict{String,Any}, cfg, "provenance"),
        Dict{String,Any}(
            "external_data_path" => resolved,
            "external_data_rows" => rows,
            "external_data_sha256" => digest,
            "declared_sample_rate" => physics.sample_rate,
            "external_data_columns" => (
                isempty(physics.external_data_columns) ?
                [TelemetryCore.PAYLOAD_COLUMN_DEFAULT] :
                copy(physics.external_data_columns)
            ),
        ),
    )
    return cfg
end

"""
    mission_plan(cfg::Dict{String,Any}; run_id = "") -> MissionPlan

Validates `cfg` (safe intervals, then the storage budget), builds the
channel models, and fixes the run ID (generated when empty); the loss
channel, the run's only random stream, is seeded with
`simulation.rng_seed`. Writes nothing to disk and leaves `cfg` unmodified:
the plan carries a shallow copy, which becomes the run's configuration
snapshot and receives in `cfg["provenance"]` the payload origin
(`payload_origin`, the content instant of payload row 1 as an ISO-8601
string) and, when `physics.data_source = "external"`, the external-input
provenance.
"""
function mission_plan(cfg::Dict{String,Any}; run_id::AbstractString = "")
    TelemetryCore.validate_config(cfg)
    TelemetryCore.check_storage_limits(cfg)
    # Shallow copy: the provenance stamp below adds a top-level section and
    # must not surface in the caller's dictionary.
    cfg = Dict{String,Any}(cfg)
    # The wall scalars are NaN in tick mode: unusable rather than silently wrong.
    sim = TelemetryCore.simulation_settings(cfg)
    mode = sim.mode
    speed_up = sim.speed_up
    start_sim = sim.start_sim_time
    wall_seconds = sim.mission_wall_seconds
    mission_days = sim.mission_days
    downtime_days = sim.initial_downtime_days
    seed = sim.rng_seed
    physics = TelemetryCore.physics_settings(cfg)
    payload_origin = Emitter.instrument_epoch(start_sim, downtime_days)
    cfg["provenance"] = Dict{String,Any}("payload_origin" => string(payload_origin))
    if physics.data_source == "external"
        stamp_external_provenance!(cfg, physics, mission_days + downtime_days)
    end
    return MissionPlan(
        cfg,
        isempty(run_id) ? TelemetryCore.generate_run_id(cfg) : String(run_id),
        speed_up,
        start_sim,
        wall_seconds,
        mode,
        mission_days,
        downtime_days,
        payload_origin,
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
    record_generation_gap!(run_dir, clock, resume; origin, sample_rate,
                           points_per_batch, hole_feed = nothing)

Bounds an emitter outage in `events_tx.csv` (Batch = `STREAM`): `gap_start`
at the content end of the last finalized batch, `gap_end` at `resume`, the
content instant at which the replacement instrument resumes. The content end
is the instant of row `payload_row + points_per_batch` of the highest
`payload_row` stamp, on the payload grid of `origin` and `sample_rate`, or
`origin` when no batch has been finalized. A content instant, rather than
the finalization or transmission instant of a logged event, places the rows
of the partial batch the failed emitter held, which no batch carries, inside
the gap. With a `hole_feed`, the same interval is appended to the
declared-hole feed as a `stream` hole declared at the current mission time.
Called before the replacement emitter is spawned, when no live `events_tx`
writer exists.
"""
function record_generation_gap!(
    run_dir::String,
    clock::TelemetryCore.MissionClock,
    resume::DateTime;
    origin::DateTime,
    sample_rate::Float64,
    points_per_batch::Int,
    hole_feed::Union{TelemetryCore.HoleFeed,Nothing} = nothing,
)
    stamped = TelemetryCore.batch_payload_rows(run_dir)
    last_gen =
        isempty(stamped) ? origin :
        TelemetryCore.payload_row_time(
            origin,
            sample_rate,
            maximum(values(stamped)) + points_per_batch,
        )
    TelemetryCore.log_tx_event(run_dir, last_gen, "STREAM", "gap_start")
    TelemetryCore.log_tx_event(run_dir, resume, "STREAM", "gap_end")
    hole_feed === nothing || TelemetryCore.declare_gap_hole!(
        hole_feed,
        TelemetryCore.get_current_sim_time(clock),
        "stream",
        last_gen,
        resume,
    )
    return nothing
end

"""
    log_component_event!(run_dir, clock, component, event)

Appends one row to the single-writer `component_events.csv`
(`SimTime,Component,Event`; events `down` and `restart`; runs made before
2.8.0 may also hold `stalled` and `recovered` from the former watchdog) through [`TelemetryCore.write_table`](@ref), the header with
the first row. Instants are written in the form of
[`TelemetryCore.timestamp_text`](@ref).
"""
function log_component_event!(
    run_dir::String,
    clock::TelemetryCore.MissionClock,
    component::Symbol,
    event::String,
)
    path = joinpath(run_dir, "component_events.csv")
    df = DataFrame(
        SimTime = [TelemetryCore.get_current_sim_time(clock)],
        Component = [String(component)],
        Event = [event],
    )
    TelemetryCore.write_table(path, df; append = isfile(path))
    return nothing
end

"""
    apply_failure_policy!(name, task, run_dir, clock, stop_flag, policy, restart_counts, spawners, on_restart) -> Union{Task,Nothing}

The supervisor's response to a component task that ended with an
exception, applied by [`supervise_ticks!`](@ref).
The failure is reported and recorded as `down`; `policy.on_component_failure`
then decides. `"restart"` calls `on_restart(name, attempt)`, relaunches
through `spawners[name]`, and returns the replacement task, up to
`policy.max_restarts` times; an exhausted budget is treated as `"abort"`.
`"continue"` leaves the partner running one-sided. `"abort"` raises
`stop_flag` so the partner stops cooperatively. Returns `nothing` when the
component stays down.
"""
function apply_failure_policy!(
    name::Symbol,
    task::Task,
    run_dir::String,
    clock::TelemetryCore.MissionClock,
    stop_flag::Threads.Atomic{Bool},
    policy::NamedTuple,
    restart_counts::Dict{Symbol,Int},
    spawners,
    on_restart::Function,
)
    stack = current_exceptions(task)
    failure = isempty(stack) ? task.result : (stack[end].exception, stack[end].backtrace)
    @error "[SUPERVISOR] Component $name failed." exception = failure
    log_component_event!(run_dir, clock, name, "down")
    if policy.on_component_failure == "restart" &&
       restart_counts[name] < policy.max_restarts
        restart_counts[name] += 1
        on_restart(name, restart_counts[name])
        replacement = spawners[name](restart_counts[name])
        log_component_event!(run_dir, clock, name, "restart")
        @warn "[SUPERVISOR] Restarted $name (attempt $(restart_counts[name]) of $(policy.max_restarts))."
        return replacement
    elseif policy.on_component_failure == "continue"
        @warn "[SUPERVISOR] Policy continue: $name stays down."
    else
        stop_flag[] = true
        @error "[SUPERVISOR] Policy abort: stopping the partner component."
    end
    return nothing
end

"""
    supervise_ticks!(spawners, run_dir, clock::TelemetryCore.TickClock, stop_flag, policy;
                     on_restart = (name, attempt) -> nothing,
                     heartbeats = Dict{Symbol,String}(),
                     halt_path = joinpath(run_dir, "HALT")) -> Dict{Symbol,Int}

Runs the components until all of them have finished and returns the restart
count per component; drives both modes, the paced wall mode and the
unpaced tick mode, through the pace of `clock`. `spawners[name](attempt)`
returns the component's task, created through
[`TelemetryCore.tick_spawn`](@ref) (attempt 0 is the primary launch,
attempt ≥ 1 a supervised restart). The tasks are driven by
[`TelemetryCore.run_ticks!`](@ref) on the calling thread; a task that ends
with an exception meets `policy.on_component_failure` through
[`apply_failure_policy!`](@ref), a restart calling
`on_restart(name, attempt)` first, up to `policy.max_restarts` times. A
task that does not park does not stall the clock, it holds it. The
heartbeat files of `heartbeats` are the driver's: touched while it releases
wakeups, removed when it returns. A paced driver stops sleeping once
`stop_flag` is raised or `halt_path` exists, so the components meet their
stop and HALT checks promptly. Lifecycle transitions are appended to `component_events.csv`;
failures, policy decisions, and restarts are logged as `[SUPERVISOR]`
records through the logger of the calling task (the global logger under
[`run_mission`](@ref); the component tasks log to their own files).
"""
function supervise_ticks!(
    spawners::Dict{Symbol,<:Function},
    run_dir::String,
    clock::TelemetryCore.TickClock,
    stop_flag::Threads.Atomic{Bool},
    policy::NamedTuple;
    on_restart::Function = (name, attempt) -> nothing,
    heartbeats::AbstractDict{Symbol,String} = Dict{Symbol,String}(),
    halt_path::AbstractString = joinpath(run_dir, "HALT"),
)
    tasks = Dict{Symbol,Task}(name => spawn(0) for (name, spawn) in spawners)
    restart_counts = Dict{Symbol,Int}(name => 0 for name in keys(spawners))
    TelemetryCore.run_ticks!(
        clock,
        tasks;
        on_task_failed = (name, task) -> apply_failure_policy!(
            name,
            task,
            run_dir,
            clock,
            stop_flag,
            policy,
            restart_counts,
            spawners,
            on_restart,
        ),
        heartbeats = heartbeats,
        should_stop = () -> stop_flag[] || isfile(halt_path),
    )
    return restart_counts
end

"""
    build_instrument(physics::NamedTuple, origin::DateTime, markers) -> VirtualInstrument.InstrumentState

The payload instrument of `[physics]` with payload origin `origin`, the
start of the initial blind spot ([`Emitter.instrument_epoch`](@ref)), where
the pre-population begins.
"""
function build_instrument(
    physics::NamedTuple,
    origin::DateTime,
    markers::Vector{TelemetryCore.EventMarker},
)
    return VirtualInstrument.InstrumentState(
        origin,
        physics.sample_rate,
        physics.segment_duration_sec,
        physics.data_source,
        physics.external_data_path;
        markers = markers,
        columns = physics.external_data_columns,
    )
end

"""
    component_spawners(plan, run_dir, clock, stop_flag, instrument,
                       pending_segments, emitter_logger, receiver_logger,
                       orig_stdout; spawn, hole_feed = nothing)
        -> Dict{Symbol,Function}

The emitter and receiver launchers consumed by [`supervise_ticks!`](@ref).
`spawn(name, f)` turns a component body into its task on the mission's tick
clock ([`TelemetryCore.tick_spawn`](@ref)). Attempt 0 continues the pre-populated
instrument and partial batch. A restarted emitter (attempt ≥ 1) starts
without a partial batch, on the instrument [`VirtualInstrument.resumed`](@ref)
from its predecessor at the current mission time; the generation gap this
leaves is bounded in `events_tx.csv` by [`record_generation_gap!`](@ref) at
the resumption instant, before the replacement task starts. `hole_feed` is
the run's declared-hole feed ([`TelemetryCore.HoleFeed`](@ref)), shared by
the emitter, the receiver, and the outage record; `nothing` writes no feed.
Both components share one on-board count, seeded from `onboard/` here and
rebuilt from its census by every emitter, restarted or not.
"""
function component_spawners(
    plan::MissionPlan,
    run_dir::String,
    clock::TelemetryCore.MissionClock,
    stop_flag::Threads.Atomic{Bool},
    instrument::VirtualInstrument.InstrumentState,
    pending_segments::Vector{TelemetryCore.DataSegment},
    emitter_logger::CleanFileLogger,
    receiver_logger::CleanFileLogger,
    orig_stdout::IO;
    spawn::Function,
    hole_feed::Union{TelemetryCore.HoleFeed,Nothing} = nothing,
)
    physics = plan.physics
    telemetry = plan.telemetry
    dashboard = plan.dashboard
    # The emitter keeps it; the receiver reads it for the metrics. Seeded
    # from the pre-populated buffer, in case no emitter reaches its census.
    onboard_path = joinpath(run_dir, "onboard")
    onboard_count = Threads.Atomic{Int}(
        count(
            f -> TelemetryCore.is_batch_name(f) && isdir(joinpath(onboard_path, f)),
            readdir(onboard_path),
        ),
    )
    run_emitter_logged(vi, pending) = with_logger(emitter_logger) do
        Emitter.run_emitter(
            clock,
            plan.link,
            run_dir,
            vi;
            batch_size = physics.batch_size,
            pending_segments = pending,
            markers = plan.markers,
            generation_gaps = plan.generation_gaps,
            onboard_capacity_batches = plan.onboard_capacity_batches,
            max_inflight_batches = telemetry.max_inflight_batches,
            stop = stop_flag,
            hole_feed = hole_feed,
            onboard_count = onboard_count,
        )
    end
    run_receiver_logged(attempt::Int) = with_logger(receiver_logger) do
        Receiver.run_receiver(
            clock,
            plan.link,
            run_dir;
            orig_stdout = orig_stdout,
            status_panel = dashboard.receiver_status_panel,
            batch_transfer_sec = telemetry.nominal_batch_transfer_sec,
            loss_model = plan.loss_model,
            max_retries = plan.max_retries,
            retention = plan.retention,
            min_link_factor = telemetry.min_link_factor,
            round_trip_light_time_sec = telemetry.round_trip_light_time_sec,
            stop = stop_flag,
            hole_feed = hole_feed,
            onboard_count = onboard_count,
        )
    end
    latest = Ref(instrument)
    function spawn_emitter(attempt::Int)
        attempt == 0 &&
            return spawn(:emitter, () -> run_emitter_logged(instrument, pending_segments))
        latest[] =
            VirtualInstrument.resumed(latest[], TelemetryCore.get_current_sim_time(clock))
        record_generation_gap!(
            run_dir,
            clock,
            latest[].last_t;
            origin = plan.payload_origin,
            sample_rate = physics.sample_rate,
            points_per_batch = TelemetryCore.points_per_batch(physics),
            hole_feed = hole_feed,
        )
        return spawn(
            :emitter,
            () -> run_emitter_logged(latest[], TelemetryCore.DataSegment[]),
        )
    end
    return Dict{Symbol,Function}(
        :emitter => spawn_emitter,
        :receiver => attempt -> spawn(:receiver, () -> run_receiver_logged(attempt)),
    )
end

# --- Post-processing ---

"""
    TIMELINE_PRODUCTS

Flags of the figure products drawn from the mask timeline; [`post_process!`](@ref)
renders them after it and the other products before it.
"""
const TIMELINE_PRODUCTS = (:state_raster,)

"""
    render_products!(plan, run_dir::String, orig_stdout::IO, selected)

Renders the flagged figure products of [`TelemetryCore.FIGURE_PRODUCTS`](@ref)
for which `selected(product)` holds, in table order, each failure-isolated.
A stage of [`post_process!`](@ref).
"""
function render_products!(plan, run_dir::String, orig_stdout::IO, selected)
    post_processing = plan.post_processing
    for product in TelemetryCore.FIGURE_PRODUCTS
        selected(product) || continue
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
    return nothing
end

"""
    post_process!(plan, run_dir; orig_stdout = stdout, figures = true)

The derived products after both components have finished. Each stage is
failure-isolated: the simulation data is already on disk, so an error is
reported but does not abort the remaining stages, and every product can be
regenerated by the standalone post-processing scripts. In order:

 1. the gap table ([`Masks.write_gap_table`](@ref)), then the declared-hole
    feed `holes.csv` settled from it ([`Masks.settle_hole_feed!`](@ref)):
    the end-of-run holes (undelivered, not generated, a recorder gap still
    open) are appended with the nominal mission end as `DeclaredAt`, so the
    feed and the table agree;
 2. the label-span table ([`Masks.write_label_spans`](@ref)), only when
    absent (it is written at mission start);
 3. the metrology tables ([`Metrology.write_metrology_tables`](@ref)),
    whatever the figure flags;
 4. the flagged figure products of [`TelemetryCore.FIGURE_PRODUCTS`](@ref)
    that do not read the mask timeline (alert latency and delivery delay);
 5. the 2D batch-state timeline (`post_processing.generate_mask_timeline`)
    and the flagged products drawn from it ([`TIMELINE_PRODUCTS`](@ref), the
    batch-state raster);
 6. the mission summary and session figures
    ([`MissionFigures.generate_mission_plots`](@ref));
 7. the HDF5 product export (`hdf5_export`) and the publication figure
    export (`[post_processing.publication]`);
 8. the run descriptor ([`TelemetryCore.write_run_descriptor`](@ref)), last
    because its hashes cover the products above.

The figure stages (4, the products of 5, and 6) and the publication export
run only when `figures` is set; the tables, the mask timeline, the HDF5
export, and the descriptor do not depend on it. The gap table and the metrology tables are cheap and precede the mask
replay and the figure stage, the long ones, so that they survive a failure
of either.

`plan` is a [`MissionPlan`](@ref) or any object with the properties read
here: `post_processing`, `ground`, `publication`, `physics`, `mission_days`,
and `initial_downtime_days`, such as the result of
[`post_processing_plan`](@ref).
"""
function post_process!(
    plan,
    run_dir::String;
    orig_stdout::IO = stdout,
    figures::Bool = true,
)
    post_processing = plan.post_processing
    # The gap table is data only and comes first, with the metrology tables.
    println(orig_stdout, "\nWriting the gap table")
    try
        Masks.write_gap_table(run_dir)
    catch e
        @error "[POST] Gap table failed — run data is intact." exception =
            (e, catch_backtrace())
    end
    try
        Masks.settle_hole_feed!(run_dir)
    catch e
        @error "[POST] Hole feed settlement failed — run data is intact." exception =
            (e, catch_backtrace())
    end
    if !isfile(joinpath(run_dir, "label_spans.csv"))
        println(orig_stdout, "\nWriting the label spans")
        try
            Masks.write_label_spans(run_dir)
        catch e
            @error "[POST] Label spans failed — run data is intact." exception =
                (e, catch_backtrace())
        end
    end
    println(orig_stdout, "\nWriting the metrology tables")
    try
        Metrology.write_metrology_tables(
            run_dir;
            lookback_hours = post_processing.alert_lookback_hours,
        )
    catch e
        @error "[POST] Metrology tables failed — run data is intact." exception =
            (e, catch_backtrace())
    end
    if figures
        render_products!(plan, run_dir, orig_stdout, p -> !(p.flag in TIMELINE_PRODUCTS))
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
    if figures
        render_products!(plan, run_dir, orig_stdout, p -> p.flag in TIMELINE_PRODUCTS)
        println(orig_stdout, "\nRendering the mission and session figures")
        try
            MissionFigures.generate_mission_plots(run_dir)
        catch e
            @error "[POST] Mission figure rendering failed — run data is intact; re-call MissionFigures.generate_mission_plots(run_dir)." exception =
                (e, catch_backtrace())
        end
    end
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
    if figures && publication.enabled
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
    # The descriptor comes last: its hashes cover the products above.
    println(orig_stdout, "\nWriting the run descriptor")
    try
        TelemetryCore.write_run_descriptor(run_dir)
    catch e
        @error "[POST] Run descriptor failed — run data is intact." exception =
            (e, catch_backtrace())
    end
    return nothing
end

"""
    post_processing_plan(cfg::AbstractDict) -> NamedTuple

What [`post_process!`](@ref) reads, taken from a configuration or a run
snapshot without building the mission models: `post_processing`, `ground`,
`publication`, `physics`, and the `[simulation]` scalars `mode`,
`mission_days` (the span in either mode), and `initial_downtime_days`. The
`retention` policy rides along for the log rotation size of
[`complete_run`](@ref).
"""
function post_processing_plan(cfg::AbstractDict)
    sim = TelemetryCore.simulation_settings(cfg)
    return (
        post_processing = TelemetryCore.post_processing_settings(cfg),
        ground = TelemetryCore.ground_settings(cfg),
        publication = TelemetryCore.publication_settings(cfg),
        physics = TelemetryCore.physics_settings(cfg),
        mode = sim.mode,
        mission_days = sim.mission_days,
        initial_downtime_days = sim.initial_downtime_days,
        retention = TelemetryCore.retention_settings(cfg),
    )
end

"""
    STRANDED_IDLE_SEC

Seconds without a write to the run directory after which [`complete_run`](@ref)
takes a stranded run for abandoned.
"""
const STRANDED_IDLE_SEC = 60.0

"""
    mission_ended(run_dir::String, anchor) -> Bool

Whether the record of a run reaches the end of its mission, `anchor` being
the result of `TelemetryCore.load_clock_anchor`, or `nothing`. For an anchor
with a horizon (both modes from 2.8.0 on), the mission instant (`SimTime`)
of the last row of `mission_profile.csv` lies within one second, or one
percent of the mission span if that is longer, of the horizon. For a wall
anchor written before 2.8.0, which has no horizon, the wall-clock instant
(`WallTime`) of that row lies within one second, or one percent of the
mission's wall-clock span if that is longer, of the anchor's
`deadline_wall`. `false` without an anchor or a profile, and for an anchor
with neither a horizon nor a wall deadline. The components write until the
end of the mission, so a profile that stops earlier is that of a process
that died during the mission.
"""
function mission_ended(run_dir::String, anchor)
    anchor === nothing && return false
    path = joinpath(run_dir, "mission_profile.csv")
    isfile(path) || return false
    lines = filter(!isempty, readlines(path))
    length(lines) >= 2 || return false
    header = strip.(split(lines[1], ','))
    fields = split(lines[end], ',')
    # Instant of the named column in the last row, `nothing` when unreadable.
    function last_instant(name::String)
        column = findfirst(==(name), header)
        column === nothing && return nothing
        length(fields) >= column || return nothing
        return try
            DateTime(strip(fields[column]))
        catch
            nothing
        end
    end
    if anchor.horizon !== nothing
        horizon = anchor.horizon
        last_sim = last_instant("SimTime")
        last_sim === nothing && return false
        span_ms = (horizon - anchor.start_sim_time).value
        tolerance = Millisecond(max(1000, round(Int, 0.01 * span_ms)))
        return last_sim >= horizon - tolerance
    end
    deadline_wall = anchor.deadline_wall
    deadline_wall === nothing && return false
    last_wall = last_instant("WallTime")
    last_wall === nothing && return false
    span_ms = (deadline_wall - anchor.wall_epoch).value
    tolerance = Millisecond(max(1000, round(Int, 0.01 * span_ms)))
    return last_wall >= deadline_wall - tolerance
end

"""
    complete_run(run_id::AbstractString; force = false, orig_stdout = stdout) -> String

Completes a stranded run: a run directory that holds `RUN_ACTIVE` and neither
`RUN_COMPLETE` nor `RUN_ABORTED` because its supervisor process was killed.
The post-processing is run again from the data on disk ([`post_process!`](@ref),
with the settings of the run's own snapshot) and the sentinels are settled:
`RUN_COMPLETE` when the mission phase had ended, `RUN_ABORTED` when the
process died before the end of its mission and the record is truncated. The
mission phase counts as ended when `RUN_POSTPROCESSING` is present or,
failing that, when [`mission_ended`](@ref) holds for `clock_anchor.toml`:
the metrics profile reaches the horizon (or, for a wall anchor written
before 2.8.0, the wall deadline) within its tolerance.

Refuses, with an `ArgumentError`, a directory that is not stranded, a paced
run whose nominal wall deadline (`deadline_wall`) has not passed, and,
unless `force` is set, a directory written to within the last
[`STRANDED_IDLE_SEC`](@ref) seconds, where a supervisor may still be
post-processing. Returns the run directory.
"""
function complete_run(run_id::AbstractString; force::Bool = false, orig_stdout::IO = stdout)
    run_dir = TelemetryCore.run_directory(String(run_id))
    isdir(run_dir) || throw(ArgumentError("[RUN] No run directory $run_dir."))
    sentinel(name) = joinpath(run_dir, name)
    stranded =
        isfile(sentinel("RUN_ACTIVE")) &&
        !isfile(sentinel("RUN_COMPLETE")) &&
        !isfile(sentinel("RUN_ABORTED"))
    stranded || throw(
        ArgumentError(
            "[RUN] $run_id is not stranded: complete_run settles a run directory that holds RUN_ACTIVE and neither RUN_COMPLETE nor RUN_ABORTED.",
        ),
    )
    anchor = try
        TelemetryCore.load_clock_anchor(run_dir)
    catch e
        e isa ArgumentError || rethrow()
        nothing
    end
    if anchor !== nothing && anchor.deadline_wall !== nothing
        deadline_wall = anchor.deadline_wall
        now() < deadline_wall && throw(
            ArgumentError(
                "[RUN] The deadline of $run_id ($deadline_wall) has not passed: the run may be live.",
            ),
        )
    end
    # Most recent write directly in the run directory or in plots/.
    newest = 0.0
    for dir in (run_dir, joinpath(run_dir, "plots"))
        isdir(dir) || continue
        for name in readdir(dir)
            path = joinpath(dir, name)
            isfile(path) && (newest = max(newest, mtime(path)))
        end
    end
    idle = time() - newest
    if !force && idle < STRANDED_IDLE_SEC
        throw(
            ArgumentError(
                "[RUN] $run_id was written to $(round(Int, idle)) s ago: a supervisor may still be post-processing. Pass force = true once no process owns the directory.",
            ),
        )
    end
    ended = isfile(sentinel("RUN_POSTPROCESSING")) || mission_ended(run_dir, anchor)
    cfg = TelemetryCore.load_run_config(run_dir)
    plan = post_processing_plan(cfg)
    with_supervisor_log(run_dir, plan.retention.log_rotate_bytes; append = true) do
        @info "[RUN] Completing a stranded run: post-processing from the data on disk." run_id mission_phase =
            ended ? "ended" : "interrupted"
        try
            post_process!(plan, run_dir; orig_stdout = orig_stdout)
        finally
            rm(sentinel("RUN_ACTIVE"), force = true)
            rm(sentinel("RUN_POSTPROCESSING"), force = true)
            touch(sentinel(ended ? "RUN_COMPLETE" : "RUN_ABORTED"))
        end
        if ended
            @info "[RUN] Settled as RUN_COMPLETE."
        else
            @warn "[RUN] The mission phase did not reach its deadline: settled as RUN_ABORTED."
        end
    end
    return run_dir
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
    if plan.mode == "tick"
        println(
            io,
            rpad("Mission span:", 20),
            "$(plan.mission_days) mission days on the tick clock (logical time)",
        )
    else
        println(
            io,
            rpad("Mission span:", 20),
            "$(plan.mission_wall_seconds) wall-clock seconds (nominal duration)",
        )
        println(io, rpad("Speed-up:", 20), "$(plan.speed_up)x")
    end
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
    execute_mission!(plan, run_dir, orig_stdout; figures = true)

The mission proper inside an existing run directory: fresh component logs,
the sequential pre-population of the onboard buffer, the mission phase on
the tick clock, and the post-processing stages ([`post_process!`](@ref),
which receives `figures`). Both modes run one path: a
[`TelemetryCore.TickClock`](@ref) spanning the mission (`plan.mission_days`
in tick mode, `speed_up · mission_wall_seconds` in wall mode), with its
persisted anchor, and the cooperative component tasks driven on this thread
([`supervise_ticks!`](@ref)), with the heartbeat files `emitter_alive` and
`receiver_alive`. In wall mode the driver paces the wakeups at `speed_up`,
so the wall budget is nominal: a host that cannot keep pace finishes later
with the same content. Touches `RUN_POSTPROCESSING` at the end of the
mission phase; the other lifecycle sentinels belong to
[`run_mission`](@ref), its caller.
"""
function execute_mission!(
    plan::MissionPlan,
    run_dir::String,
    orig_stdout::IO;
    figures::Bool = true,
)
    emitter_log = joinpath(run_dir, "emitter.log")
    receiver_log = joinpath(run_dir, "receiver.log")
    write(emitter_log, "")
    write(receiver_log, "") # fresh logs for this run
    rotate_bytes = plan.retention.log_rotate_bytes
    emitter_logger = CleanFileLogger(emitter_log, rotate_bytes)
    receiver_logger = CleanFileLogger(receiver_log, rotate_bytes)
    physics = plan.physics
    # The declared-hole feed, shared by the pre-population, both components,
    # and the outage record.
    hole_feed = TelemetryCore.HoleFeed(
        run_dir,
        plan.payload_origin,
        physics.sample_rate,
        TelemetryCore.points_per_batch(physics),
    )

    # Pre-populate the onboard buffer sequentially before the clock starts;
    # the returned instrument and partial batch continue into the main loop.
    println(
        orig_stdout,
        "Pre-populating the onboard buffer for $(plan.initial_downtime_days) days",
    )
    instrument, pending_segments = with_logger(emitter_logger) do
        Emitter.pre_populate(
            build_instrument(physics, plan.payload_origin, plan.markers),
            plan.start_sim,
            run_dir;
            batch_size = physics.batch_size,
            markers = plan.markers,
            generation_gaps = plan.generation_gaps,
            onboard_capacity_batches = plan.onboard_capacity_batches,
            hole_feed = hole_feed,
            progress = orig_stdout !== devnull,
        )
    end

    stop_flag = Threads.Atomic{Bool}(false)
    # One clock for both modes: the tick clock spans the mission, and in wall
    # mode the driver paces its wakeups at `speed_up`. Compilation and a
    # lagging host delay the wall instants, not the content.
    span_days =
        plan.mode == "wall" ? plan.speed_up * plan.mission_wall_seconds / 86_400 :
        plan.mission_days
    horizon = plan.start_sim + Millisecond(round(Int, span_days * TelemetryCore.MS_PER_DAY))
    clock = TelemetryCore.TickClock(
        plan.start_sim,
        horizon;
        pace = plan.mode == "wall" ? plan.speed_up : nothing,
    )
    TelemetryCore.save_clock_anchor(run_dir, clock)
    TelemetryCore.save_markers(
        run_dir,
        plan.markers;
        origin = plan.payload_origin,
        sample_rate = plan.physics.sample_rate,
    )
    Masks.write_label_spans(run_dir)
    print_banner(orig_stdout, plan, run_dir)
    priority = Dict(
        :emitter => TelemetryCore.EMITTER_PRIORITY,
        :receiver => TelemetryCore.RECEIVER_PRIORITY,
    )
    spawners = component_spawners(
        plan,
        run_dir,
        clock,
        stop_flag,
        instrument,
        pending_segments,
        emitter_logger,
        receiver_logger,
        orig_stdout;
        spawn = (name, f) -> TelemetryCore.tick_spawn(clock, priority[name], f),
        hole_feed = hole_feed,
    )
    supervise_ticks!(
        spawners,
        run_dir,
        clock,
        stop_flag,
        plan.supervision;
        heartbeats = Dict(
            :emitter => joinpath(run_dir, "emitter_alive"),
            :receiver => joinpath(run_dir, "receiver_alive"),
        ),
    )
    rm(joinpath(run_dir, "HALT"), force = true) # consumed if an operator halted the run

    # Mission phase over: payload and event logs are final; only derived
    # products are written from here on.
    touch(joinpath(run_dir, "RUN_POSTPROCESSING"))
    post_process!(plan, run_dir; orig_stdout = orig_stdout, figures = figures)
    println(orig_stdout, "\n=== MISSION COMPLETE ===")
    println(orig_stdout, "Results saved in: $run_dir")
    println(orig_stdout, "Summary plots available in: $(joinpath(run_dir, "plots"))")
    return nothing
end

"""
    run_mission(cfg::Dict{String,Any}; run_id = "", orig_stdout = stdout,
                figures = true, data_root = TelemetryCore.DATA_ROOT[]) -> String

The headless pipeline end to end: [`mission_plan`](@ref) (validation,
storage gate, models, provenance), the run directory
`<data_root>/runs/<run_id>` with its configuration snapshot, and
[`execute_mission!`](@ref) under [`with_supervisor_log`](@ref). Returns the
run directory. `figures = false` skips every figure stage and the
publication export (the sweep driver uses it); the tables are written
regardless.

Lifecycle sentinels: `RUN_ACTIVE` while the pipeline may still write, with
`RUN_POSTPROCESSING` beside it from the end of the mission phase to the end
of the lifecycle; then `RUN_COMPLETE` at lifecycle end or `RUN_ABORTED` on
any escaping exception. `RUN_COMPLETE` marks the end of the lifecycle, not
success: a failed component still reaches it after the failure-isolated
post-processing. A directory left with `RUN_ACTIVE` and no process is
settled by [`complete_run`](@ref).
"""
function run_mission(
    cfg::Dict{String,Any};
    run_id::AbstractString = "",
    orig_stdout::IO = stdout,
    figures::Bool = true,
    data_root::AbstractString = TelemetryCore.DATA_ROOT[],
)
    plan = mission_plan(cfg; run_id = run_id)
    run_dir = TelemetryCore.setup_run_dir(
        plan.run_id;
        cfg = plan.cfg,
        data_root = String(data_root),
    )
    rm(joinpath(run_dir, "RUN_COMPLETE"), force = true)
    rm(joinpath(run_dir, "RUN_POSTPROCESSING"), force = true)
    touch(joinpath(run_dir, "RUN_ACTIVE"))
    completed = false
    try
        with_supervisor_log(run_dir, plan.retention.log_rotate_bytes) do
            execute_mission!(plan, run_dir, orig_stdout; figures = figures)
        end
        completed = true
    finally
        # Sentinels consistent on every exit path: an abort before lifecycle
        # end must not strand RUN_ACTIVE (a consumer would see a live run
        # with no process).
        rm(joinpath(run_dir, "RUN_ACTIVE"), force = true)
        rm(joinpath(run_dir, "RUN_POSTPROCESSING"), force = true)
        touch(joinpath(run_dir, completed ? "RUN_COMPLETE" : "RUN_ABORTED"))
    end
    return run_dir
end

end # module Supervisor
