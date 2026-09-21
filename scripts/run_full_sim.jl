include(joinpath(@__DIR__, "activate.jl"))
using DeepSpaceTelemetry

# Headless entry point: argument parsing plus one call. Any argument ending
# in ".toml" selects an alternative configuration file (e.g. scenario.toml);
# any other argument is taken as the run ID. Order-independent, both
# optional. The pipeline itself — validation, storage gate, models,
# supervised components, sentinels, post-processing — is
# Supervisor.run_mission.
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

DeepSpaceTelemetry.Supervisor.run_mission(
    DeepSpaceTelemetry.TelemetryCore.load_config(config_arg);
    run_id = run_id,
)
