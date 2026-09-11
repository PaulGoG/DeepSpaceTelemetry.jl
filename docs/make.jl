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

makedocs(
    doctest = true,
    sitename = "DeepSpaceTelemetry",
    authors = "Paul-Adrian Gogîță <gogitapaul@yahoo.ro>",
    repo = Documenter.Remotes.GitHub("PaulGoG", "DeepSpaceTelemetry.jl"),
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/",
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

# The CI docs job pushes the build to the `gh-pages` branch: `dev` from
# `main`, `stable` and `vX.Y.Z` from version tags. Outside CI, or without a
# token, Documenter skips the deployment and the local build stays in
# `docs/build/`.
deploydocs(
    repo = "github.com/PaulGoG/DeepSpaceTelemetry.jl",
    devbranch = "main",
    push_preview = false,
)
