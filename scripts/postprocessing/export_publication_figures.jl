"""
Publication figure export (command-line wrapper)
================================================

Re-renders every figure of a run at the printed width and in the vector
format declared in the run's `[post_processing.publication]` settings
(`enabled` is ignored here), into the configured export directory
(default `<run_dir>/publication`) with a `PROVENANCE.toml` sidecar
(`Publication.export_publication_figures`).

Usage:
    julia export_publication_figures.jl [run_id]

Without an argument the most recently modified run directory is exported.
"""

using Pkg;
Pkg.activate(joinpath(@__DIR__, ".."), io = devnull);
Pkg.instantiate(io = devnull)
using DeepSpaceTelemetry

run_id = isempty(ARGS) ? DeepSpaceTelemetry.TelemetryCore.latest_run_id() : ARGS[1]
if run_id === nothing
    println("Error: no run directory found; pass a run ID.")
    exit(1)
end
run_dir = DeepSpaceTelemetry.TelemetryCore.run_directory(run_id)
settings = DeepSpaceTelemetry.TelemetryCore.publication_settings(
    DeepSpaceTelemetry.TelemetryCore.load_run_config(run_dir),
)
paths = DeepSpaceTelemetry.Publication.export_publication_figures(
    run_dir;
    format = settings.format,
    column_width_mm = settings.column_width_mm,
    export_dir = settings.export_dir,
)
println("Exported $(length(paths)) figures:")
foreach(p -> println("  ", p), paths)
