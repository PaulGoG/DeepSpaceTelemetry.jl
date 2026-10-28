include(joinpath(@__DIR__, "activate.jl"))

# Ensembles and sweeps on the tick clock: the configuration once per seed,
# with optional overrides of any key, the realized totals of every run in
# one table under data/sweeps/<PREFIX>/.
#
#   julia scripts/run_sweep.jl <config.toml> <PREFIX> --seeds 1:8 [--workers 4] [--set packet_loss.p_loss=0.2 ...]
#
# `--seeds` takes a range (a:b) or a comma-separated list; `--workers N`
# runs N members at once on N threads (serial without it), restarting the
# script with --threads=N when Julia was started with fewer; every
# `--set section.key=value` applies to all runs.
config_arg = ""
prefix = ""
seeds = Int[]
workers = 0
overrides = String[]
args = copy(ARGS)
empty!(ARGS)
i = 1
while i <= length(args)
    a = args[i]
    if a == "--seeds"
        global i += 1
        text = args[i]
        global seeds =
            occursin(':', text) ?
            collect(parse(Int, split(text, ':')[1]):parse(Int, split(text, ':')[end])) :
            parse.(Int, split(text, ','))
    elseif a == "--workers"
        global i += 1
        global workers = parse(Int, args[i])
    elseif a == "--set"
        global i += 1
        push!(overrides, args[i])
    elseif endswith(a, ".toml")
        global config_arg = a
    else
        global prefix = a
    end
    global i += 1
end
isempty(config_arg) && error(
    "usage: julia scripts/run_sweep.jl <config.toml> <PREFIX> --seeds a:b [--workers N] [--set key=value ...]",
)
isempty(prefix) && error("A run-ID prefix is required.")
isempty(seeds) && error("--seeds is required.")

# Parallel members need threads; the script restarts itself once with enough.
if workers > Threads.nthreads() && !haskey(ENV, "DEEPSPACETELEMETRY_SWEEP_RELAUNCH")
    relaunch = `$(Base.julia_cmd()) --threads=$workers $(abspath(PROGRAM_FILE)) $args`
    relaunch = addenv(relaunch, "DEEPSPACETELEMETRY_SWEEP_RELAUNCH" => "1")
    exit(something(run(ignorestatus(relaunch)).exitcode, 1))
end

using DeepSpaceTelemetry

cfg = DeepSpaceTelemetry.TelemetryCore.load_config(config_arg)
result = DeepSpaceTelemetry.Sweeps.run_sweep(
    cfg;
    prefix = prefix,
    seeds = seeds,
    overrides = overrides,
    workers = workers,
)
println("Sweep $prefix: $(size(result.summary, 1)) runs; summary in $(result.dir)")
show(stdout, result.summary)
println()
