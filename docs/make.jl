include(joinpath(@__DIR__, "activate.jl"))
using Documenter
using DeepSpaceTelemetry
using DeepSpaceTelemetryHeadless
using DeepSpaceTelemetryReader

# Doctest blocks in the docstrings run in a fresh module with these imports.
for pkg in (DeepSpaceTelemetry, DeepSpaceTelemetryHeadless, DeepSpaceTelemetryReader)
    DocMeta.setdocmeta!(
        pkg,
        :DocTestSetup,
        :(using DeepSpaceTelemetry;
        using DeepSpaceTelemetry: TelemetryCore, ChannelEffects;
        using Dates;
        using Random: Xoshiro);
        recursive = true,
    )
end

makedocs(
    doctest = true,
    sitename = "DeepSpaceTelemetry",
    authors = "Paul-Adrian Gogîță",
    repo = Documenter.Remotes.GitHub("PaulGoG", "DeepSpaceTelemetry.jl"),
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/",
        description = "Manual of DeepSpaceTelemetry.jl, a telemetry, channel, and queuing simulator for deep-space science missions, with LISA as the shipped scenario library.",
        # The TelemetryCore API page is about 204 KiB, above Documenter's
        # default thresholds (error 200 KiB, warning 100 KiB); both are raised.
        size_threshold_warn = 150 * 2^10,
        size_threshold = 250 * 2^10,
    ),
    modules = [
        DeepSpaceTelemetry,
        DeepSpaceTelemetryHeadless,
        DeepSpaceTelemetryReader,
        DeepSpaceTelemetry.TelemetryCore,
        DeepSpaceTelemetry.ChannelEffects,
        DeepSpaceTelemetry.VirtualInstrument,
        DeepSpaceTelemetry.PlotTheme,
        DeepSpaceTelemetry.Emitter,
        DeepSpaceTelemetry.Receiver,
        DeepSpaceTelemetry.Masks,
        DeepSpaceTelemetry.MissionFigures,
        DeepSpaceTelemetry.Metrology,
        DeepSpaceTelemetry.MetrologyFigures,
        DeepSpaceTelemetry.Export,
        DeepSpaceTelemetry.Publication,
        DeepSpaceTelemetry.Supervisor,
        DeepSpaceTelemetry.RunAdapter,
        DeepSpaceTelemetry.Sweeps,
    ],
    pages = [
        "Home" => "index.md",
        "Physics & Queuing Theory" => "physics.md",
        "Usage & Configuration" => "usage.md",
        "Scenario Gallery" => "gallery.md",
        "Analysis Interfaces" => "interfaces.md",
        "Headless Package and Containers" => "headless.md",
        "Upgrading and Support" => "upgrading.md",
        "API Reference" => [
            "Overview" => "api.md",
            "TelemetryCore" => "api/telemetrycore.md",
            "ChannelEffects" => "api/channeleffects.md",
            "VirtualInstrument" => "api/virtualinstrument.md",
            "Emitter" => "api/emitter.md",
            "Receiver" => "api/receiver.md",
            "Masks" => "api/masks.md",
            "MissionFigures" => "api/missionfigures.md",
            "Metrology" => "api/metrology.md",
            "MetrologyFigures" => "api/metrologyfigures.md",
            "Export" => "api/export.md",
            "Publication" => "api/publication.md",
            "Supervisor" => "api/supervisor.md",
            "RunAdapter" => "api/runadapter.md",
            "Sweeps" => "api/sweeps.md",
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
