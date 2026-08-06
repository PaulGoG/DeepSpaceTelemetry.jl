using Pkg;
Pkg.activate(joinpath(@__DIR__, ".."), io = devnull);
Pkg.instantiate(io = devnull)

# Guarded include: launch_dashboard.jl loads the module before including this
# script, and re-including would replace the module mid-flight.
if !isdefined(Main, :DeepSpaceTelemetry)
    include("../src/DeepSpaceTelemetry.jl")
end
using .DeepSpaceTelemetry
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

const SPEED_UP = Float64(cfg["simulation"]["speed_up"])
const START_SIM = DateTime(cfg["simulation"]["start_sim_time"])
const TEST_DURATION_SEC = Float64(cfg["simulation"]["test_duration_sec"])
const INITIAL_DOWNTIME_DAYS = Float64(cfg["simulation"]["initial_downtime_days"])
const RNG_SEED = Int(get(cfg["simulation"], "rng_seed", 0))

const MAX_BATCHES_PER_HOUR = Float64(cfg["telemetry"]["max_batches_per_hour"])

const DATA_SOURCE = get(cfg["physics"], "data_source", "synthetic")
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

emitter_log = joinpath(run_dir, "emitter.log")
receiver_log = joinpath(run_dir, "receiver.log")
write(emitter_log, "");
write(receiver_log, "") # fresh logs for this run

# Pre-populate onboard buffer sequentially before starting the clock.
# The returned instrument (and any partial batch) is handed to the main loop so
# the data stream continues where pre-population stopped.
println("Pre-populating onboard buffer for $(INITIAL_DOWNTIME_DAYS) days...")
instrument, leftover_segs =
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
        )
    end

clock = DeepSpaceTelemetry.TelemetryCore.SimulationClock(now(), START_SIM, SPEED_UP)

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

function run_emitter_logged()
    with_logger(get_clean_logger(emitter_log; rotate_bytes = retention.log_rotate_bytes)) do
        DeepSpaceTelemetry.Emitter.run_emitter(
            clock,
            link,
            run_id;
            test_duration_sec = TEST_DURATION_SEC,
            sample_rate = SAMPLE_RATE,
            seg_dur = SEG_DUR,
            batch_size = BATCH_SIZE,
            data_source = DATA_SOURCE,
            ext_path = EXT_PATH,
            instrument = instrument,
            initial_segments = leftover_segs,
        )
    end
end

function run_receiver_logged()
    with_logger(
        get_clean_logger(receiver_log; rotate_bytes = retention.log_rotate_bytes),
    ) do
        DeepSpaceTelemetry.Receiver.run_receiver(
            clock,
            link,
            run_id;
            test_duration_sec = TEST_DURATION_SEC,
            orig_stdout = orig_stdout,
            max_batches_per_hour = MAX_BATCHES_PER_HOUR,
            loss_model = loss_model,
            max_retries = max_retries,
            retention = retention,
        )
    end
end

# Spawn both
emitter_task = Threads.@spawn run_emitter_logged()
receiver_task = Threads.@spawn run_receiver_logged()

# Wait
try
    wait(emitter_task)
    wait(receiver_task)
catch e
    println(orig_stdout, "\n[ERROR] Simulation task failed:")
    if isa(e, TaskFailedException)
        showerror(orig_stdout, e.task.exception)
    else
        showerror(orig_stdout, e)
    end
    println(orig_stdout)
end

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
rm(joinpath(run_dir, "RUN_ACTIVE"), force = true)
touch(joinpath(run_dir, "RUN_COMPLETE"))

println(orig_stdout, "\n=== MISSION COMPLETE ===")
println(orig_stdout, "Results saved in: $run_dir")
println(orig_stdout, "Summary plots available in: $(joinpath(run_dir, "plots"))")
