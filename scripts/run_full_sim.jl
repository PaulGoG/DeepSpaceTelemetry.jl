include(joinpath(@__DIR__, "activate.jl"))
using DeepSpaceTelemetry

# Headless entry point: argument parsing plus one call. Any argument ending
# in ".toml" selects an alternative configuration file (e.g. scenario.toml);
# `--tick` runs the configuration on the logical clock with its span
# unchanged (TelemetryCore.tick_configuration); any other argument is taken
# as the run ID. Order-independent, all optional. The pipeline itself —
# validation, storage gate, models, supervised components, sentinels,
# post-processing — is Supervisor.run_mission.
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
