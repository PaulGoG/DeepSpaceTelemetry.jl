# Upgrading and Support

## Support

Since 3.0 the package is in maintenance. Patch releases fix defects and
keep the dependencies current; minor releases add to the surface below
without changing what is there. The file contract, the configuration
schema, the entry-point scripts and `RunAdapter` stay backward compatible
within 3.x ([Design Principles](@ref)). Anything removed from that surface
first warns through at least one minor release, as everything 3.0 removed
did in 2.11. Where the contract records a writer's deviation from it, the
correction comes in a minor release if it changes what a consumer reads
from the tick-clock runs of the shipped scenarios, and in a patch release
otherwise; either way it is listed below.

The supported Julia versions are 1.12 and the current stable release; the
continuous integration runs the current release on Linux, macOS and Windows
and 1.12 on Linux. Defects are reported as issues of the
[repository](https://github.com/PaulGoG/DeepSpaceTelemetry.jl/issues), with the
run's `descriptor.toml` where a run is involved.

## From 3.3.1 to 3.3.2

The interfaces are unchanged. A configuration or a sweep that 3.3.1
accepted outside the documented schema may now stop before the run:

| 3.3.1 | 3.3.2 |
|---|---|
| `inf` for a key converted to an instant, a period or a count: accepted, then an `InexactError` in the run, or the mission aborted (the range) | refused with a `[CONFIG]` error that names the key; `inf` for a key the configuration does not use (`low_latency_after_hours` without a low-latency period, `recovery_hours` of a generation event) passes as before |
| a value that is no array in place of an array of tables: `events = ""` read as no events | refused; `events = []` is no events |
| a section that is no table: a `MethodError`, or, for `[provenance]` and `[payload]`, accepted | refused |
| `run_sweep.jl --seeds a:step:b` ran `a:b` | runs the stepped range |
| `--set` of a key outside the schema, of an array of tables or of `[provenance]`: the runs kept the default | refused |

The products of a run that 3.3.1 completed are unchanged except where the
changelog lists a fix: a transfer that fills its contact window, the marker
latency over data the recorder discarded, and the count of discarded
batches.

## From 3.2 to 3.3

The simulator is now the package `DeepSpaceTelemetryHeadless`
([Headless Package and Containers](@ref)). The main package re-exports its
modules under the same names, so code that loads `DeepSpaceTelemetry`
reaches them as before. What changes for a user of 3.2:

| 3.2 | 3.3 |
|---|---|
| `Metrology.plot_alert_latency`, `Metrology.plot_delivery_delay` | `MetrologyFigures.plot_alert_latency`, `MetrologyFigures.plot_delivery_delay`; the tables stay in `Metrology` |
| the HDF5 export loads with the package | an extension of the headless package, loaded with `HDF5`; the main package loads it, and `Export.hdf5_available()` tells whether it is there |
| `events_rx.csv`: the `SimTime` of `ingested`, `retry` and `lost` is the start of the transfer | the completion instant of the transfer; delivery delays and alert latencies grow by about one transfer time, more where a transfer spans the end of a pass |
| `alert_latency.csv`: a row where a window completed under both doctrines | a row wherever a live event's window lies within the run; on the added rows `N_Alerts = 0` and the complete-case quantiles are `NaN`; the Kaplan–Meier columns follow the existing ones |
| `Export.HDF5`, `Export.ensure_group`, `Export.write_column!`, `Export.write_table!`, `Export.write_mask_timeline!`, `Export.write_provenance!` | moved into the extension `DeepSpaceTelemetryHeadlessHDF5Ext`; `Export.export_hdf5` is the interface |
| `Receiver.ServicePacer`, `Receiver.serve_slot!` | removed |

The configuration schema and `RunAdapter` are unchanged; a configuration of
3.2 runs as it is.

## From 2.x to 3.0

When 3.0 rejects a configuration, the `[CONFIG]` error names the key and its remedy. The changes:

| 2.x | 3.0 |
|---|---|
| `post_processing.expand_to_pointwise_masks`, `target_event_rows`, `masks/pointwise_mask_*.csv`, the HDF5 group `masks/pointwise/`, `scripts/postprocessing/apply_telemetry_mask.jl`, `standalone_mask_expander.jl`, `Masks.expand_pointwise_mask` | removed; `RunAdapter.delivered_rows(run; at)` returns the delivered payload rows at any mission instant as row intervals, exact across generation gaps, where the masks placed batches by position |
| `RunAdapter.GapTracker`, `declare!`, `open_gaps` | removed; `RunAdapter.declared_holes` reads `holes.csv`, and `RunAdapter.FeedCursor(run, :holes)` follows it by byte offset |
| `RunAdapter.MINIMUM_PRODUCER_VERSION` = 2.1.0 | 2.6.0: runs of earlier producers, without `holes.csv` and `label_spans.csv`, open only with `open_run(run; minimum_version)` lowered, and the readers no longer derive their missing parts; a batch without a `payload_row` stamp (producers before 2.1.0) is an error |
| `storage.onboard_capacity_days` | `telemetry.onboard_capacity_days`; the snapshot of an earlier run is still read |
| `supervision.watchdog_sec` | removed (no effect since 2.8.0) |
| `storage.bytes_*` | removed; `[storage]` holds `max_storage_gb`, `max_file_count` and `max_ram_gb` |
| keys retired at 1.0.0 (`simulation.test_duration_sec`, `simulation.max_storage_gb`, `physics.signal_injection_probability`, `post_processing.generate_batch_matrix`, the `[disaster]` section) | no longer recognized: `validate_config` warns that they are ignored |
| `descriptor.toml` `schema = "deepspacetelemetry-run/1"` | `"deepspacetelemetry-run/2"`: the point-wise masks are gone from the run directory |

The shipped scenarios took this form in 2.11, so a configuration derived
from one of them since 2.11 needs no change. The products of a run are
otherwise those of 2.11.
