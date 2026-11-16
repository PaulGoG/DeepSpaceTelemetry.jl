# The suite runs in test/Project.toml, which takes both packages from this
# checkout through [sources], and loads them with `using`: Aqua, JET and
# ExplicitImports need the package identity, which `include` would lose.
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

# One enclosing testset: a failing file does not abort the files after it,
# and each testset prints its time.
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
