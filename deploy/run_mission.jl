include(joinpath(@__DIR__, "activate.jl"))
using DeepSpaceTelemetryHeadless: TelemetryCore, Supervisor

# A mission and its tables, without figures, on the headless package.
# Arguments in any order: a path ending in ".toml" selects the configuration
# (required), `--tick` runs it on the logical clock with its span unchanged
# (TelemetryCore.tick_configuration), and any other argument is the run ID.
# Runs go under the data root: DEEPSPACETELEMETRY_DATA when set, else
# headless/data.
config_arg = ""
run_id = ""
tick = false
for a in ARGS
    if endswith(a, ".toml")
        global config_arg = a
    elseif a == "--tick"
        global tick = true
    else
        global run_id = a
    end
end
empty!(ARGS)
isempty(config_arg) &&
    error("[CONFIG] Usage: julia deploy/run_mission.jl <config.toml> [RUN_ID] [--tick]")

cfg = TelemetryCore.load_config(config_arg)
tick && (cfg = TelemetryCore.tick_configuration(cfg))
Supervisor.run_mission(cfg; run_id = run_id, figures = false)
