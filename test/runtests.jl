# The suite runs in its own environment (test/Project.toml, the package taken
# from the parent directory through [sources]) and loads DeepSpaceTelemetry as
# a real package, never via include, so Aqua, JET, and ExplicitImports resolve
# the package identity.
include(joinpath(@__DIR__, "activate.jl"))
using Test, Dates, Statistics, CSV, DataFrames, Logging, TOML
using StableRNGs
using Aqua, JET, ExplicitImports
using DeepSpaceTelemetry
using DeepSpaceTelemetry:
    TelemetryCore,
    ChannelEffects,
    VirtualInstrument,
    Emitter,
    Receiver,
    Masks,
    MissionFigures,
    Metrology,
    Export,
    Publication,
    PlotTheme,
    Supervisor

# The entire suite writes its runs into a disposable data root: the real
# data/ tree stays untouched even if the process is killed mid-suite.
TelemetryCore.DATA_ROOT[] = mktempdir()

include("helpers.jl")
include("static_qa.jl")
include("telemetrycore.jl")
include("channeleffects.jl")
include("virtualinstrument.jl")
include("masks.jl")
include("integration.jl")
include("supervisor.jl")
include("metrology.jl")
include("export.jl")
include("figures.jl")
