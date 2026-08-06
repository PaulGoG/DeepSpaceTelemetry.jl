module DeepSpaceTelemetry

include("TelemetryCore.jl")
include("ChannelEffects.jl")
include("VirtualInstrument.jl")
include("PlotTheme.jl")
include("Emitter.jl")
include("Receiver.jl")

export TelemetryCore, ChannelEffects, VirtualInstrument, PlotTheme, Emitter, Receiver

end # module DeepSpaceTelemetry
