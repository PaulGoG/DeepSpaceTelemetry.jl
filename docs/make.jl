using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using Documenter
using DeepSpaceTelemetry

# Doctest blocks in the docstrings run in a fresh module with these imports.
DocMeta.setdocmeta!(
    DeepSpaceTelemetry,
    :DocTestSetup,
    :(using DeepSpaceTelemetry;
    using DeepSpaceTelemetry: TelemetryCore, ChannelEffects;
    using Dates;
    using Random: Xoshiro);
    recursive = true,
)

# Deployment (`deploydocs`) is added when the repository becomes public: GitHub
# Pages does not serve a private repository on the free plan, so the CI docs
# job only builds the manual until then.
makedocs(
    doctest = true,
    sitename = "DeepSpaceTelemetry",
    authors = "Paul-Adrian Gogîță <gogitapaul@yahoo.ro>",
    repo = Documenter.Remotes.GitHub("PaulGoG", "DeepSpaceTelemetry.jl"),
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        # The TelemetryCore API page renders at about 105 KiB; the default
        # 100 KiB warning threshold is raised, the 200 KiB error stays.
        size_threshold_warn = 150 * 2^10,
    ),
    modules = [
        DeepSpaceTelemetry,
        DeepSpaceTelemetry.TelemetryCore,
        DeepSpaceTelemetry.ChannelEffects,
        DeepSpaceTelemetry.VirtualInstrument,
        DeepSpaceTelemetry.PlotTheme,
        DeepSpaceTelemetry.Emitter,
        DeepSpaceTelemetry.Receiver,
        DeepSpaceTelemetry.Metrology,
        DeepSpaceTelemetry.Export,
        DeepSpaceTelemetry.Publication,
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
            "Export" => "api/export.md",
            "Publication" => "api/publication.md",
            "Supervisor" => "api/supervisor.md",
            "PlotTheme" => "api/plottheme.md",
        ],
    ],
)
