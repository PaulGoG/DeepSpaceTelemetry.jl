"""
    DeepSpaceTelemetryHeadless

The simulator of DeepSpaceTelemetry without its figures: the channel and
instrument models, the emitter and the receiver on the tick driver, the
post-processing tables, the mission supervisor and sweeps. Every package of
its dependency closure carries a permissive licence (`test/licences.toml`),
so it can be installed in a container or bundled in a system image without
the terms of the figure stack. `DeepSpaceTelemetry` re-exports these modules and adds the
figures; loaded alone, a mission writes every table and no figure. The HDF5
export is an extension, loaded with the HDF5 package. Submodules:
`TelemetryCore` and `RunAdapter` (from the reader package), `ChannelEffects`,
`VirtualInstrument`, `Emitter`, `Receiver`, `Masks`, `Metrology`, `Export`,
`Supervisor`, `Sweeps`.
"""
module DeepSpaceTelemetryHeadless

using DeepSpaceTelemetryReader: DeepSpaceTelemetryReader, TelemetryCore, RunAdapter

"Absolute path of this package's root."
const PACKAGE_ROOT = dirname(@__DIR__)

function __init__()
    # On its own the package addresses its own directory; DeepSpaceTelemetry,
    # loaded after it, points both roots at its own.
    TelemetryCore.PROJECT_ROOT[] = PACKAGE_ROOT
    TelemetryCore.DATA_ROOT[] = TelemetryCore.default_data_root(PACKAGE_ROOT)
    return nothing
end

include("ChannelEffects.jl")
include("VirtualInstrument.jl")
include("Emitter.jl")
include("Receiver.jl")
include("Masks.jl")
include("Metrology.jl")
include("Export.jl")
include("Supervisor.jl")
include("Sweeps.jl")

export TelemetryCore,
    RunAdapter,
    ChannelEffects,
    VirtualInstrument,
    Emitter,
    Receiver,
    Masks,
    Metrology,
    Export,
    Supervisor,
    Sweeps

using PrecompileTools: @setup_workload, @compile_workload
using Logging: NullLogger, with_logger

@setup_workload begin
    # A short tick mission without figures: the configuration layer, the
    # pre-population, both component loops, the event, metrics and hole
    # writers, and the post-processing tables.
    cfg = Dict{String,Any}(
        "simulation" => Dict{String,Any}(
            "mode" => "tick",
            "mission_days" => 0.05,
            "initial_downtime_days" => 0.02,
            "start_sim_time" => "2035-01-01T07:00:00",
            "rng_seed" => 1,
        ),
        "telemetry" => Dict{String,Any}(
            "session_start" => "07:00:00",
            "session_duration_hours" => 8.0,
            "max_batches_per_hour" => 20.0,
            "bandwidth_profile" => "flat",
        ),
        "physics" => Dict{String,Any}(
            "data_source" => "synthetic",
            "sample_rate" => 1.0,
            "segment_duration_sec" => 60.0,
            "batch_size" => 10,
        ),
        "packet_loss" => Dict{String,Any}(
            "enabled" => true,
            "model" => "bernoulli",
            "p_loss" => 0.1,
        ),
    )
    @compile_workload begin
        mktempdir() do data_root
            with_logger(NullLogger()) do
                Supervisor.run_mission(
                    cfg;
                    run_id = "PRECOMPILE",
                    orig_stdout = devnull,
                    figures = false,
                    data_root = data_root,
                )
            end
        end
    end
end

end # module DeepSpaceTelemetryHeadless
