include(joinpath(@__DIR__, "activate.jl"))
using DeepSpaceTelemetry

# Headless entry point. Arguments, all optional and in any order: a path
# ending in ".toml" selects the configuration (e.g. scenario.toml), `--tick`
# runs it on the logical clock with its span unchanged
# (TelemetryCore.tick_configuration), and any other argument is the run ID.
# The pipeline is Supervisor.run_mission.
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

cfg = DeepSpaceTelemetry.TelemetryCore.load_config(config_arg)
tick && (cfg = DeepSpaceTelemetry.TelemetryCore.tick_configuration(cfg))
DeepSpaceTelemetry.Supervisor.run_mission(cfg; run_id = run_id)
