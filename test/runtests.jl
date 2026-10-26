# The suite runs in its own environment (test/Project.toml, the package taken
# from the parent directory through [sources]) and loads DeepSpaceTelemetry as
# a real package, never via include, so Aqua, JET, and ExplicitImports resolve
# the package identity.
include(joinpath(@__DIR__, "activate.jl"))
using Test, Dates, Statistics, CSV, DataFrames, Logging, TOML
using StableRNGs
using Aqua, JET, ExplicitImports
using DeepSpaceTelemetry
using DeepSpaceTelemetryReader
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
    Supervisor,
    RunAdapter,
    Sweeps

# The entire suite writes its runs into a disposable data root: the real
# data/ tree stays untouched even if the process is killed mid-suite.
TelemetryCore.DATA_ROOT[] = mktempdir()

# A single enclosing testset, so a failing file no longer aborts the files after
# it and the per-testset times are printed.
@testset verbose = true "DeepSpaceTelemetry" begin
    include("helpers.jl")
    include("static_qa.jl")
    include("telemetrycore.jl")
    include("sourceidentity.jl")
    include("channeleffects.jl")
    include("virtualinstrument.jl")
    include("masks.jl")
    include("integration.jl")
    include("supervisor.jl")
    include("tickmode.jl")
    include("runadapter.jl")
    include("sweeps.jl")
    include("metrology.jl")
    include("export.jl")
    include("figures.jl")
    # Opt-in: a run from a copy installed by Pkg, which precompiles from scratch.
    get(ENV, "DEEPSPACETELEMETRY_TEST_INSTALLED", "false") == "true" &&
        include("installed_copy.jl")
end
