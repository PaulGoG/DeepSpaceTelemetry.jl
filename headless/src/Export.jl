"""
    Export

HDF5 product export: the consumer-facing products of a run (event logs,
hole feed, metrics profile, batch-state timeline, batch epochs, gap table,
metrology tables, markers, label spans, component events)
in one self-describing file with the run's provenance as attributes, for
analysis pipelines that read HDF5 rather than a directory of CSV files. The
CSV products remain the primary interface; the export is a derived,
regenerable view of them ([`export_hdf5`](@ref)). The writer is an extension
of the package, loaded with HDF5 ([`hdf5_available`](@ref)), so that the
dependency closure of the package holds no HDF5 binary.
"""
module Export

using ..TelemetryCore: TelemetryCore

"""
    FORMAT_VERSION

Layout version of the exported file, stored as the root attribute
`format_version`; incremented when a group or dataset changes meaning.
"""
const FORMAT_VERSION = "1"

"""
    TABLE_PRODUCTS

`(group, relative path)` pairs of the tabular CSV products written by
[`export_hdf5`](@ref), one group each; absent files are skipped.
"""
const TABLE_PRODUCTS = (
    ("events/tx", "events_tx.csv"),
    ("events/rx", "events_rx.csv"),
    ("holes", "holes.csv"),
    ("metrics/mission_profile", "mission_profile.csv"),
    ("masks/batch_epochs", joinpath("masks", "batch_epochs.csv")),
    ("masks/gaps", joinpath("masks", "gaps.csv")),
    ("metrology/alert_latency", "alert_latency.csv"),
    ("metrology/alert_latency_markers", "alert_latency_markers.csv"),
    ("metrology/delivery_delay", "delivery_delay.csv"),
    ("markers", "markers.csv"),
    ("label_spans", "label_spans.csv"),
    ("component_events", "component_events.csv"),
)

"""
    hdf5_available() -> Bool

Whether the HDF5 writer is loaded: the extension
`DeepSpaceTelemetryHeadlessHDF5Ext`, which Julia loads with the HDF5 package.
`DeepSpaceTelemetry` loads HDF5; the headless package alone does not.
"""
hdf5_available() = hdf5_extension() !== nothing

hdf5_extension() =
    Base.get_extension(parentmodule(@__MODULE__), :DeepSpaceTelemetryHeadlessHDF5Ext)

"""
    export_hdf5(run_dir::String; path = joinpath(run_dir, "products.h5")) -> String

Writes the run's products into one HDF5 file (default
`<run_dir>/products.h5`, an existing file is rotated to `products#k.h5`):
the tabular products of [`TABLE_PRODUCTS`](@ref) as column datasets, the
batch-state timeline, and the provenance attributes. Times are seconds since the run's
`start_sim_time` with ISO-8601 twins. Returns the file path. Throws an `ArgumentError` when HDF5 is not loaded
([`hdf5_available`](@ref)).
"""
function export_hdf5(run_dir::String; path::String = joinpath(run_dir, "products.h5"))
    ext = hdf5_extension()
    ext === nothing && throw(
        ArgumentError(
            "[EXPORT] The HDF5 export needs the HDF5 package loaded (using HDF5); DeepSpaceTelemetry loads it.",
        ),
    )
    return Base.invokelatest(ext.write_hdf5, run_dir, path)
end

end # module Export
