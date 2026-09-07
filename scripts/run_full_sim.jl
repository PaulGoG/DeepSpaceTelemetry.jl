using Pkg;
Pkg.activate(@__DIR__, io = devnull);
Pkg.instantiate(io = devnull)

using DeepSpaceTelemetry
using Dates, CSV, DataFrames
using Logging, LoggingExtras, TerminalLoggers
using Random
using SHA

function strip_ansi(msg::AbstractString)
    return replace(msg, r"\e\[[0-9;]*[a-zA-Z]" => "")
end

function get_clean_logger(log_path::String; rotate_bytes::Real = 64 * 1024^2)
    # One line per record: "[Level] message" — no `└ @ Module file:line`
    # source-location suffix (pure noise when tailed in a dashboard terminal).
    # Structured kwargs (e.g. exception=...) are kept on indented lines, with
    # exceptions rendered compactly (showerror, no raw backtrace pointers).
    # Formatting must never throw: a throwing logger would kill the task it
    # logs for, so every value is stringified defensively.
    #
    # Records are appended per-write (open/close each record): log rates are
    # a few lines per batch, so the cost is negligible, and it enables
    # size-capped rotation to `name#k.log` (retention.log_rotate_mb) without
    # juggling a held-open stream across the rotation boundary.
    fmt = FormatLogger(; always_flush = false) do _, args
        if isfile(log_path) && filesize(log_path) > rotate_bytes
            DeepSpaceTelemetry.TelemetryCore.backup_existing(log_path)
        end
        open(log_path, "a") do stream
            try
                println(stream, "[", args.level, "] ", args.message)
                for (k, v) in pairs(args.kwargs)
                    vs = try
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
                    println(stream, "    ", k, " = ", vs)
                end
            catch
                println(stream, "[Warn] <log record could not be formatted>")
            end
        end
    end
    return TransformerLogger(fmt) do log
        msg = log.message isa AbstractString ? strip_ansi(log.message) : log.message
        return merge(log, (message = msg,))
    end
end
# 1. Load Config
# CLI: any argument ending in ".toml" selects an alternative config file
# (e.g. scenario.toml); any other argument is taken as the run ID.
# Order-independent, both optional.
config_arg = ""
run_id = ""
for a in ARGS
    if endswith(a, ".toml")
        global config_arg = a
    else
        global run_id = a
    end
end
empty!(ARGS)

cfg = DeepSpaceTelemetry.TelemetryCore.load_config(config_arg)

# Pre-run validation (safe parameter intervals) + storage safety check
DeepSpaceTelemetry.TelemetryCore.validate_config(cfg)
DeepSpaceTelemetry.TelemetryCore.check_storage_limits(cfg)

# Single-thread advisory: the components are cooperative tasks (see
# TelemetryCore.thread_advisory); a warning, never a refusal.
let advisory = DeepSpaceTelemetry.TelemetryCore.thread_advisory()
    advisory === nothing || @warn advisory
end

const SPEED_UP = Float64(cfg["simulation"]["speed_up"])
const START_SIM = DateTime(cfg["simulation"]["start_sim_time"])
const TEST_DURATION_SEC = Float64(cfg["simulation"]["test_duration_sec"])
const INITIAL_DOWNTIME_DAYS = Float64(cfg["simulation"]["initial_downtime_days"])
const RNG_SEED = Int(get(cfg["simulation"], "rng_seed", 0))

const TELEMETRY = DeepSpaceTelemetry.TelemetryCore.telemetry_settings(cfg)
const MAX_BATCHES_PER_HOUR = TELEMETRY.max_batches_per_hour

const DATA_SOURCE = get(cfg["physics"], "data_source", "synthetic")
const SIGNAL_INJECTION_PROBABILITY =
    Float64(get(cfg["physics"], "signal_injection_probability", 0.02))
const MAX_INFLIGHT_BATCHES = TELEMETRY.max_inflight_batches
const MIN_LINK_FACTOR = TELEMETRY.min_link_factor
const EXT_PATH = get(cfg["physics"], "external_data_path", "")
const SAMPLE_RATE = Float64(cfg["physics"]["sample_rate"])
const SEG_DUR = Float64(cfg["physics"]["segment_duration_sec"])
const BATCH_SIZE = Int(cfg["physics"]["batch_size"])

# Channel models: composite link (visibility × disruptions) + stochastic loss.
# Component RNGs get distinct seeds derived from simulation.rng_seed so the
# physics stream and the loss realizations are independently reproducible.
link = DeepSpaceTelemetry.ChannelEffects.build_link_model(cfg)
loss_model = DeepSpaceTelemetry.ChannelEffects.build_loss_model(cfg, RNG_SEED + 1)
max_retries = DeepSpaceTelemetry.ChannelEffects.loss_retry_limit(cfg)
retention = DeepSpaceTelemetry.TelemetryCore.retention_settings(cfg)
instrument_rng = Xoshiro(RNG_SEED)

# External-input coverage report + provenance stamp. Row count and content
# hash are computed up front — before any directory exists — so exhaustion is
# predicted at startup rather than discovered mid-mission, and the snapshot
# pins the exact input the run consumed (works for foreign data: no sidecar
# or generator metadata is assumed).
if DATA_SOURCE == "external"
    ext_resolved =
        isabspath(EXT_PATH) ? EXT_PATH :
        joinpath(DeepSpaceTelemetry.TelemetryCore.PROJECT_ROOT, EXT_PATH)
    ext_rows = max(countlines(ext_resolved) - 1, 0) # header-inclusive count; ≈ for headerless files
    ext_sha = open(io -> bytes2hex(sha256(io)), ext_resolved)
    needed_days = (TEST_DURATION_SEC * SPEED_UP / 86_400.0) + INITIAL_DOWNTIME_DAYS
    covered_days = ext_rows / SAMPLE_RATE / 86_400.0
    if covered_days + 1e-9 < needed_days
        @warn "[INPUT] External data covers ≈ $(round(covered_days, digits=2)) of $(round(needed_days, digits=2)) mission days at the declared $(SAMPLE_RATE) Hz — the stream zero-pads from day $(round(covered_days, digits=2)) on."
    else
        @info "[INPUT] External data covers ≈ $(round(covered_days, digits=2)) mission days (mission needs $(round(needed_days, digits=2)))."
    end
    cfg["provenance"] = Dict{String,Any}(
        "external_data_path" => ext_resolved,
        "external_data_rows" => ext_rows,
        "external_data_sha256" => ext_sha,
        "declared_sample_rate" => SAMPLE_RATE,
    )
end

# 2. Setup Run
if isempty(run_id)
    run_id = DeepSpaceTelemetry.TelemetryCore.generate_run_id()
end
run_dir = DeepSpaceTelemetry.TelemetryCore.setup_run_dir(run_id; cfg = cfg)

# Lifecycle sentinels for filesystem consumers (docs/src/interfaces.md):
# RUN_ACTIVE while the pipeline may still write, RUN_COMPLETE afterwards.
rm(joinpath(run_dir, "RUN_COMPLETE"), force = true)
touch(joinpath(run_dir, "RUN_ACTIVE"))
# Sentinel truthfulness on any exit path: an abort before lifecycle end must
# not strand RUN_ACTIVE (consumers would see a live run with no process).
mission_completed = Ref(false)
atexit() do
    if !mission_completed[]
        rm(joinpath(run_dir, "RUN_ACTIVE"), force = true)
        touch(joinpath(run_dir, "RUN_ABORTED"))
    end
end

emitter_log = joinpath(run_dir, "emitter.log")
receiver_log = joinpath(run_dir, "receiver.log")
write(emitter_log, "");
write(receiver_log, "") # fresh logs for this run

# Pre-populate onboard buffer sequentially before starting the clock.
# The returned instrument (and any partial batch) is handed to the main loop so
# the data stream continues where pre-population stopped.
println("Pre-populating onboard buffer for $(INITIAL_DOWNTIME_DAYS) days...")
instrument, pending_segments =
    with_logger(get_clean_logger(emitter_log; rotate_bytes = retention.log_rotate_bytes)) do
        DeepSpaceTelemetry.Emitter.pre_populate(
            START_SIM,
            run_id;
            sample_rate = SAMPLE_RATE,
            seg_dur = SEG_DUR,
            batch_size = BATCH_SIZE,
            initial_downtime_days = INITIAL_DOWNTIME_DAYS,
            data_source = DATA_SOURCE,
            ext_path = EXT_PATH,
            rng = instrument_rng,
            signal_injection_probability = SIGNAL_INJECTION_PROBABILITY,
        )
    end

clock = DeepSpaceTelemetry.TelemetryCore.SimulationClock(now(), START_SIM, SPEED_UP)

# Shared absolute deadline + persisted anchor: both loops terminate at the
# same wall instant regardless of spawn jitter, and a re-attaching component
# reconstructs the identical mission clock (component outages simply elapse
# as mission time).
mission_deadline = clock.start_real_time + Millisecond(round(Int, TEST_DURATION_SEC * 1000))
DeepSpaceTelemetry.TelemetryCore.save_clock_anchor(run_dir, clock, mission_deadline)

# Supervision policy
sup_cfg = get(cfg, "supervision", Dict{String,Any}())
const ON_FAILURE = lowercase(String(get(sup_cfg, "on_component_failure", "abort")))
const MAX_RESTARTS = Int(get(sup_cfg, "max_restarts", 3))
const WATCHDOG_SEC = Float64(get(sup_cfg, "watchdog_sec", 30.0))
stop_flag = Threads.Atomic{Bool}(false)
heartbeats = Dict(
    :emitter => joinpath(run_dir, "emitter_alive"),
    :receiver => joinpath(run_dir, "receiver_alive"),
)

println("="^55)
println(lpad("DEEP-SPACE TELEMETRY MISSION START", 44))
println("="^55)
println(rpad("Run ID:", 20), run_id)
println(rpad("Test Duration:", 20), "$TEST_DURATION_SEC seconds")
println(rpad("Speed-up:", 20), "$(SPEED_UP)x")
println(rpad("Logs:", 20), "$run_dir/*.log")
println("="^55)

# 3. Execution with Redirected Output
orig_stdout = stdout

# Component spawners: attempt 0 is the primary launch; attempt ≥ 1 is a
# supervised restart. A restarted emitter takes a fresh instrument anchored
# at the current mission time (honest generation gap, new noise realization
# on a derived seed) and no carried-over partial batch.
function run_emitter_logged(attempt::Int = 0)
    with_logger(get_clean_logger(emitter_log; rotate_bytes = retention.log_rotate_bytes)) do
        DeepSpaceTelemetry.Emitter.run_emitter(
            clock,
            link,
            run_id;
            sample_rate = SAMPLE_RATE,
            seg_dur = SEG_DUR,
            batch_size = BATCH_SIZE,
            data_source = DATA_SOURCE,
            ext_path = EXT_PATH,
            instrument = attempt == 0 ? instrument : nothing,
            pending_segments = attempt == 0 ? pending_segments :
                               DeepSpaceTelemetry.TelemetryCore.DataSegment[],
            rng = attempt == 0 ? instrument_rng : Xoshiro(RNG_SEED + 100 + attempt),
            signal_injection_probability = SIGNAL_INJECTION_PROBABILITY,
            max_inflight_batches = MAX_INFLIGHT_BATCHES,
            deadline = mission_deadline,
            stop = stop_flag,
            heartbeat_path = heartbeats[:emitter],
        )
    end
end

function run_receiver_logged(attempt::Int = 0)
    with_logger(
        get_clean_logger(receiver_log; rotate_bytes = retention.log_rotate_bytes),
    ) do
        DeepSpaceTelemetry.Receiver.run_receiver(
            clock,
            link,
            run_id;
            orig_stdout = orig_stdout,
            max_batches_per_hour = MAX_BATCHES_PER_HOUR,
            loss_model = loss_model,
            max_retries = max_retries,
            retention = retention,
            min_link_factor = MIN_LINK_FACTOR,
            deadline = mission_deadline,
            stop = stop_flag,
            heartbeat_path = heartbeats[:receiver],
        )
    end
end

spawners = Dict{Symbol,Function}(
    :emitter => a -> Threads.@spawn(run_emitter_logged(a)),
    :receiver => a -> Threads.@spawn(run_receiver_logged(a)),
)

# Component-outage record (single writer: this supervisor). Consumed by
# post-processing and external consumers alike.
component_events_path = joinpath(run_dir, "component_events.csv")
function log_component_event(component::Symbol, event::String)
    header = !isfile(component_events_path)
    open(component_events_path, "a") do io
        header && println(io, "SimTime,Component,Event")
        println(
            io,
            DeepSpaceTelemetry.TelemetryCore.get_current_sim_time(clock),
            ",",
            component,
            ",",
            event,
        )
    end
end

# Supervisor: post-processing must never overlap a live task, RUN_COMPLETE
# must be truthful, and a single component's death must not silently waste
# the run (policy: abort | continue | restart with bounded relaunches).
tasks = Dict(name => sp(0) for (name, sp) in spawners)
restart_counts = Dict(:emitter => 0, :receiver => 0)
failure_handled = Set{Symbol}()
watchdog_tripped = Set{Symbol}()
while !all(istaskdone, values(tasks))
    sleep(DeepSpaceTelemetry.TelemetryCore.RECEIVER_POLL_INTERVAL_SEC)
    for (name, t) in collect(tasks)
        (istaskfailed(t) && !(name in failure_handled)) || continue
        println(orig_stdout, "\n[SUPERVISOR] Component $name failed:")
        showerror(orig_stdout, t.result)
        println(orig_stdout)
        log_component_event(name, "down")
        if ON_FAILURE == "restart" && restart_counts[name] < MAX_RESTARTS
            restart_counts[name] += 1
            if name == :emitter
                # No live events_tx writer exists at this instant: record the
                # generation gap bounds before the replacement starts.
                tx_log_path = joinpath(run_dir, "events_tx.csv")
                last_gen =
                    isfile(tx_log_path) ?
                    maximum(
                        CSV.read(tx_log_path, DataFrame).SimTime;
                        init = clock.start_sim_time,
                    ) : clock.start_sim_time
                DeepSpaceTelemetry.TelemetryCore.log_tx_event(
                    run_dir,
                    last_gen,
                    "STREAM",
                    "gap_start",
                )
                DeepSpaceTelemetry.TelemetryCore.log_tx_event(
                    run_dir,
                    DeepSpaceTelemetry.TelemetryCore.get_current_sim_time(clock),
                    "STREAM",
                    "gap_end",
                )
            end
            tasks[name] = spawners[name](restart_counts[name])
            log_component_event(name, "restart")
            println(
                orig_stdout,
                "[SUPERVISOR] Restarted $name (attempt $(restart_counts[name]) of $MAX_RESTARTS).",
            )
        elseif ON_FAILURE == "continue"
            push!(failure_handled, name)
            println(orig_stdout, "[SUPERVISOR] Policy continue: $name stays down.")
        else
            push!(failure_handled, name)
            stop_flag[] = true
            println(
                orig_stdout,
                "[SUPERVISOR] Policy abort: stopping the partner component.",
            )
        end
    end
    # Watchdog: a hung (not dead) component stops heartbeating.
    for (name, heartbeat_file) in heartbeats
        t = tasks[name]
        (istaskdone(t) || !isfile(heartbeat_file)) && continue
        stalled = time() - mtime(heartbeat_file) > WATCHDOG_SEC
        if stalled && !(name in watchdog_tripped)
            push!(watchdog_tripped, name)
            log_component_event(name, "stalled")
            println(
                orig_stdout,
                "\n[SUPERVISOR] Watchdog: no heartbeat from $name for > $(WATCHDOG_SEC) s.",
            )
        elseif !stalled && name in watchdog_tripped
            delete!(watchdog_tripped, name)
            log_component_event(name, "recovered")
        end
    end
end
for t in values(tasks)
    try
        wait(t)
    catch
        # Failure already reported by the supervisor loop.
    end
end
rm(joinpath(run_dir, "HALT"), force = true) # consumed if an operator halted the run

# Post-run stages are failure-isolated: the simulation data is already on
# disk, so a post-processing error is reported loudly but never aborts the
# remaining stages (each product can be regenerated by the standalone
# scripts/postprocessing tools).

# Generate the 2D batch-state matrix (masks/telemetry_mask_timeline.csv)
if get(cfg, "post_processing", Dict()) |> pp -> get(pp, "generate_batch_matrix", true)
    println(orig_stdout, "\nGenerating Post-Processing Telemetry Masks...")
    try
        DeepSpaceTelemetry.Receiver.generate_telemetry_masks(run_dir)
    catch e
        @error "[POST] Mask-matrix generation failed — run data is intact." exception =
            (e, catch_backtrace())
    end
end

if get(cfg, "post_processing", Dict()) |> pp -> get(pp, "expand_to_pointwise_masks", false)
    println(orig_stdout, "\nExpanding Telemetry Masks to Point-Wise 0/1 Arrays...")
    try
        include(joinpath("postprocessing", "apply_telemetry_mask.jl"))

        total_sim_sec = TEST_DURATION_SEC * SPEED_UP + (INITIAL_DOWNTIME_DAYS * 24 * 3600)
        total_segs = ceil(Int, total_sim_sec / SEG_DUR)
        total_pts = round(Int, total_segs * SEG_DUR * SAMPLE_RATE)

        target_rows_config = get(cfg["post_processing"], "target_event_rows", [-1])
        target_rows =
            DeepSpaceTelemetry.TelemetryCore.normalize_target_rows(target_rows_config)

        if target_rows === :all
            mask_path = joinpath(run_dir, "masks", "telemetry_mask_timeline.csv")
            mask_df = CSV.read(mask_path, DataFrame)
            target_rows = collect(1:nrow(mask_df))
        end

        for row_idx in target_rows
            out_name =
                row_idx == -1 ? "pointwise_mask_final.csv" :
                "pointwise_mask_t$(row_idx).csv"
            out_path = joinpath(run_dir, "masks", out_name)
            try
                apply_mask(run_id, total_pts, row_idx, out_path)
            catch e
                @error "[POST] Point-wise expansion failed for row $row_idx — continuing with the remaining rows." exception =
                    (e, catch_backtrace())
            end
        end
    catch e
        @error "[POST] Point-wise mask expansion stage failed — run data is intact." exception =
            (e, catch_backtrace())
    end
end

# Lifecycle handoff: no pipeline stage writes into the run directory beyond
# this point (RUN_COMPLETE marks lifecycle end, not success — a failed task
# above still reaches here after the failure-isolated post-processing).
mission_completed[] = true
rm(joinpath(run_dir, "RUN_ACTIVE"), force = true)
touch(joinpath(run_dir, "RUN_COMPLETE"))

println(orig_stdout, "\n=== MISSION COMPLETE ===")
println(orig_stdout, "Results saved in: $run_dir")
println(orig_stdout, "Summary plots available in: $(joinpath(run_dir, "plots"))")
