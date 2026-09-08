using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using Documenter
using DeepSpaceTelemetry

makedocs(
    sitename = "DeepSpaceTelemetry",
    authors = "Paul-Adrian Gogîță <gogitapaul@yahoo.ro>",
    repo = Documenter.Remotes.GitHub("PaulGoG", "DeepSpaceTelemetry.jl"),
    format = Documenter.HTML(prettyurls = get(ENV, "CI", nothing) == "true"),
    modules = [
        DeepSpaceTelemetry,
        DeepSpaceTelemetry.TelemetryCore,
        DeepSpaceTelemetry.ChannelEffects,
        DeepSpaceTelemetry.VirtualInstrument,
        DeepSpaceTelemetry.PlotTheme,
        DeepSpaceTelemetry.Emitter,
        DeepSpaceTelemetry.Receiver,
        DeepSpaceTelemetry.Metrology,
        DeepSpaceTelemetry.Supervisor,
    ],
    pages = [
        "Home" => "index.md",
        "Physics & Queuing Theory" => "physics.md",
        "Usage & Configuration" => "usage.md",
        "Analysis Interfaces" => "interfaces.md",
        "API Reference" => [
            "Overview" => "api.md",
            "TelemetryCore" => "api/telemetrycore.md",
            "ChannelEffects" => "api/channeleffects.md",
            "VirtualInstrument" => "api/virtualinstrument.md",
            "Emitter" => "api/emitter.md",
            "Receiver" => "api/receiver.md",
            "Metrology" => "api/metrology.md",
            "Supervisor" => "api/supervisor.md",
            "PlotTheme" => "api/plottheme.md",
        ],
    ],
)
