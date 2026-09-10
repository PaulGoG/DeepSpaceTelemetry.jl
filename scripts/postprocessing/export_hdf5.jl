"""
HDF5 product export (command-line wrapper)
==========================================

Writes every consumer-facing product of a run — event logs, metrics
profile, batch-state timeline, batch epochs, point-wise masks, metrology
tables, markers, component events — into `<run_dir>/products.h5` with the
run's provenance as attributes (`Export.export_hdf5`). The CSV products
remain in place; the file is a derived view for HDF5-based pipelines.

Usage:
    julia export_hdf5.jl [run_id]

Without an argument the most recently modified run directory is exported.
"""

using Pkg;
Pkg.activate(joinpath(@__DIR__, ".."), io = devnull);
Pkg.instantiate(io = devnull)
using DeepSpaceTelemetry

run_id = isempty(ARGS) ? DeepSpaceTelemetry.TelemetryCore.latest_run_id() : ARGS[1]
if run_id === nothing
    "no run directory found; pass a run ID"
    exit(1)
end
println(
    "Exported: ",
    DeepSpaceTelemetry.Export.export_hdf5(
        DeepSpaceTelemetry.TelemetryCore.run_directory(run_id),
    ),
)
