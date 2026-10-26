include(joinpath(@__DIR__, "activate.jl"))
using Documenter
using DeepSpaceTelemetry
using DeepSpaceTelemetryReader

# Doctest blocks in the docstrings run in a fresh module with these imports.
for pkg in (DeepSpaceTelemetry, DeepSpaceTelemetryReader)
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
        # The TelemetryCore API page is about 200 KiB, at the default error
        # threshold (200 KiB; warning at 100 KiB), so both are raised.
        size_threshold_warn = 150 * 2^10,
        size_threshold = 250 * 2^10,
    ),
    modules = [
        DeepSpaceTelemetry,
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
