"""
    DeepSpaceTelemetry

Simulation framework for the telemetry environment of deep-space science
missions: duty-cycled ground-station contact windows, a physical downlink
with stochastic loss and scheduled disruptions, live-FIFO/archive-LIFO
routing, and provenance-tracked data products. The shipped scenarios model
the LISA mission; the telemetry, channel, and queuing layers are
mission-agnostic. The simulator is the package `DeepSpaceTelemetryHeadless`,
whose modules are re-exported here under the same names; this package adds
the figures and loads HDF5, which enables the HDF5 export. Submodules:
`TelemetryCore` and `RunAdapter` (from the reader package
`DeepSpaceTelemetryReader`), `ChannelEffects`, `VirtualInstrument`,
`Emitter`, `Receiver`, `Masks`, `Metrology`, `Export`, `Supervisor`,
`Sweeps` (from `DeepSpaceTelemetryHeadless`), and `PlotTheme`,
`MissionFigures`, `MetrologyFigures`, `Publication`.
"""
module DeepSpaceTelemetry

using DeepSpaceTelemetryReader: DeepSpaceTelemetryReader, TelemetryCore, RunAdapter
using DeepSpaceTelemetryHeadless:
    DeepSpaceTelemetryHeadless,
    ChannelEffects,
    VirtualInstrument,
    Emitter,
    Receiver,
    Masks,
    Metrology,
    Export,
    Supervisor,
    Sweeps
# Loading HDF5 loads the HDF5 export of the headless package (its extension).
using HDF5: HDF5

"Absolute path of this package's root: the directory of `config.toml`, `scenarios/` and `data/`."
const PACKAGE_ROOT = dirname(@__DIR__)

function __init__()
    # The reader package addresses this package's files and records its identity.
    TelemetryCore.PROJECT_ROOT[] = PACKAGE_ROOT
    TelemetryCore.DATA_ROOT[] = TelemetryCore.default_data_root(PACKAGE_ROOT)
    return nothing
end

include("PlotTheme.jl")
include("MissionFigures.jl")
include("MetrologyFigures.jl")
include("Publication.jl")

export TelemetryCore,
    ChannelEffects,
    VirtualInstrument,
    PlotTheme,
    Emitter,
    Receiver,
    Masks,
    MissionFigures,
    Metrology,
    MetrologyFigures,
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
