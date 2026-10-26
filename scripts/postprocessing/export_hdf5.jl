# Writes the consumer-facing products of a run, with its provenance as
# attributes, into <run_dir>/products.h5 (Export.export_hdf5), a derived view
# for HDF5-based pipelines; the CSV products stay in place. Argument: the run
# ID, by default that of the most recently modified run directory.

include(joinpath(@__DIR__, "..", "activate.jl"))
using DeepSpaceTelemetry

run_id = isempty(ARGS) ? DeepSpaceTelemetry.TelemetryCore.latest_run_id() : ARGS[1]
if run_id === nothing
    @error "No run directory found; pass a run ID."
    exit(1)
end
println(
    "Exported: ",
    DeepSpaceTelemetry.Export.export_hdf5(
        DeepSpaceTelemetry.TelemetryCore.run_directory(run_id),
    ),
)
