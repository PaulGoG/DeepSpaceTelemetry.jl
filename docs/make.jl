using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using Documenter
using DeepSpaceTelemetry

makedocs(
    sitename = "DeepSpaceTelemetry",
    remotes = nothing,
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true"
    ),
    modules = [
        DeepSpaceTelemetry,
        DeepSpaceTelemetry.TelemetryCore,
        DeepSpaceTelemetry.ChannelEffects,
        DeepSpaceTelemetry.VirtualInstrument,
        DeepSpaceTelemetry.PlotTheme,
        DeepSpaceTelemetry.Emitter,
        DeepSpaceTelemetry.Receiver,
    ],
    pages = [
        "Home" => "index.md",
        "Physics & Queuing Theory" => "physics.md",
        "Usage & Configuration" => "usage.md",
        "Analysis Interfaces" => "interfaces.md",
        "API Reference" => "api.md"
    ]
)
