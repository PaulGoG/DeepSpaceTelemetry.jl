# Re-renders every figure of a run at the printed width and in the vector
# format of its [post_processing.publication] settings (`enabled` is ignored
# here) into the configured export directory, by default <run_dir>/publication,
# with a PROVENANCE.toml sidecar (Publication.export_publication_figures).
# Argument: the run ID, by default that of the most recently modified run
# directory.

include(joinpath(@__DIR__, "..", "activate.jl"))
using DeepSpaceTelemetry

run_id = isempty(ARGS) ? DeepSpaceTelemetry.TelemetryCore.latest_run_id() : ARGS[1]
if run_id === nothing
    @error "No run directory found; pass a run ID."
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
