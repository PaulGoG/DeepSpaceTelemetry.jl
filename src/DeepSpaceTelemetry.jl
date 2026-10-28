"""
    DeepSpaceTelemetry

Simulation framework for the telemetry environment of deep-space science
missions: duty-cycled ground-station contact windows, a physical downlink
with stochastic loss and scheduled disruptions, live-FIFO/archive-LIFO
routing, and provenance-tracked data products. The shipped scenarios model
the LISA mission; the telemetry, channel, and queuing layers are
mission-agnostic. Submodules: `TelemetryCore` and `RunAdapter` (from the
reader package `DeepSpaceTelemetryReader`, re-exported here),
`ChannelEffects`, `VirtualInstrument`, `PlotTheme`, `Emitter`, `Receiver`,
`Masks`, `MissionFigures`, `Metrology`, `Export`, `Publication`,
`Supervisor`, `Sweeps`.
"""
module DeepSpaceTelemetry

using DeepSpaceTelemetryReader: DeepSpaceTelemetryReader, TelemetryCore, RunAdapter

"Absolute path of this package's root: the directory of `config.toml`, `scenarios/` and `data/`."
const PACKAGE_ROOT = dirname(@__DIR__)

function __init__()
    # The reader package addresses this package's files and records its identity.
    TelemetryCore.PROJECT_ROOT[] = PACKAGE_ROOT
    TelemetryCore.DATA_ROOT[] = joinpath(PACKAGE_ROOT, "data")
    return nothing
end

include("ChannelEffects.jl")
include("VirtualInstrument.jl")
include("PlotTheme.jl")
include("Emitter.jl")
include("Receiver.jl")
include("Masks.jl")
include("MissionFigures.jl")
include("Metrology.jl")
include("Export.jl")
include("Publication.jl")
include("Supervisor.jl")
include("Sweeps.jl")

export TelemetryCore,
    ChannelEffects,
    VirtualInstrument,
    PlotTheme,
    Emitter,
    Receiver,
    Masks,
    MissionFigures,
    Metrology,
    Export,
    Publication,
    Supervisor,
    RunAdapter,
    Sweeps

using PrecompileTools: @setup_workload, @compile_workload
using Logging: NullLogger, with_logger

@setup_workload begin
    scenario = joinpath(PACKAGE_ROOT, "scenarios", "smoke_1d.toml")
    @compile_workload begin
        # A short tick mission end to end in a temporary data root: the
        # configuration layer, the pre-population, both component loops on the
        # tick driver, the event, metrics, and hole writers, the
        # post-processing tables, and the figure stage.
        cfg = TelemetryCore.tick_configuration(TelemetryCore.load_config(scenario))
        cfg["simulation"]["mission_days"] = 0.05
        cfg["simulation"]["initial_downtime_days"] = 0.02
        mktempdir() do data_root
            with_logger(NullLogger()) do
                Supervisor.run_mission(
                    cfg;
                    run_id = "PRECOMPILE",
                    orig_stdout = devnull,
                    figures = true,
                    data_root = data_root,
                )
            end
        end
    end
end

end # module DeepSpaceTelemetry
