"""
    DeepSpaceTelemetry

Simulation framework for the telemetry environment of deep-space science
missions: duty-cycled ground-station contact windows, a physical downlink
with stochastic loss and scheduled disruptions, live-FIFO/archive-LIFO
routing, and provenance-tracked data products. The shipped scenarios model
the LISA mission; the telemetry, channel, and queuing layers are
mission-agnostic. Submodules: `TelemetryCore`, `ChannelEffects`,
`VirtualInstrument`, `PlotTheme`, `Emitter`, `Receiver`, `Masks`, `MissionFigures`, `Metrology`,
`Export`, `Publication`, `Supervisor`.
"""
module DeepSpaceTelemetry

include("TelemetryCore.jl")
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
    Supervisor

using PrecompileTools: @setup_workload, @compile_workload
using Dates: DateTime, Time, Second

@setup_workload begin
    precompile_cfg = Dict{String,Any}(
        "simulation" => Dict{String,Any}(
            "speed_up" => 3600.0,
            "start_sim_time" => "2035-01-01T06:00:00",
            "mission_wall_seconds" => 10.0,
            "initial_downtime_days" => 0.0,
            "rng_seed" => 1,
        ),
        "storage" => Dict{String,Any}("max_storage_gb" => 2.0),
        "telemetry" => Dict{String,Any}(
            "session_start" => "08:00:00",
            "session_duration_hours" => 8.0,
            "max_batches_per_hour" => 20.0,
            "bandwidth_profile" => "sine",
        ),
        "physics" => Dict{String,Any}(
            "data_source" => "synthetic",
            "sample_rate" => 4.0,
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
        # Exercise the configuration, estimation, link, channel, and
        # synthesis paths that dominate time-to-first-run.
        TelemetryCore.validate_config(precompile_cfg)
        TelemetryCore.estimate_artifacts(precompile_cfg)
        vis = TelemetryCore.VisibilityModel(Time(8), Second(8 * 3600), "sine")
        TelemetryCore.get_bandwidth_factor(vis, DateTime(2035, 1, 1, 12))
        loss = ChannelEffects.build_loss_model(precompile_cfg, 1)
        ChannelEffects.sample_loss!(loss)
        vi = VirtualInstrument.InstrumentState(DateTime(2035), 4.0, 60.0, "synthetic", "")
        VirtualInstrument.next_segment!(vi)
    end
end

end # module DeepSpaceTelemetry
