# Upgrading and Support

## Support

Since 3.0 the package is maintained rather than extended. Patch releases fix
defects and keep the dependencies current; the file contract, the
configuration schema, the entry-point scripts and `RunAdapter` stay as they
are within 3.x (Design Principles in the Analysis Interfaces page). Anything
removed from that surface first warns through at least one minor release,
as everything 3.0 removed did in 2.11.

The supported Julia versions are 1.12 and the current stable release; the
continuous integration runs the current release on Linux, macOS and Windows
and 1.12 on Linux. Defects are reported as issues of the
[repository](https://github.com/PaulGoG/DeepSpaceTelemetry.jl/issues), with the
run's `descriptor.toml` where a run is involved.

## From 2.x to 3.0

A configuration that 3.0 rejects names the key and its remedy. The changes:

| 2.x | 3.0 |
|---|---|
| `post_processing.expand_to_pointwise_masks`, `target_event_rows`, `masks/pointwise_mask_*.csv`, the HDF5 group `masks/pointwise/`, `scripts/postprocessing/apply_telemetry_mask.jl`, `standalone_mask_expander.jl`, `Masks.expand_pointwise_mask` | removed; `RunAdapter.delivered_rows(run; at)` returns the delivered payload rows at any mission instant as row intervals, exact across generation gaps, where the masks placed batches by position |
| `RunAdapter.GapTracker`, `declare!`, `open_gaps` | removed; `RunAdapter.declared_holes` reads `holes.csv`, and `RunAdapter.FeedCursor(run, :holes)` follows it by byte offset |
| `RunAdapter.MINIMUM_PRODUCER_VERSION` = 2.1.0 | 2.6.0: runs of earlier producers, without `holes.csv` and `label_spans.csv`, open only with `open_run(run; minimum_version)` lowered, and the readers no longer derive their missing parts |
| `storage.onboard_capacity_days` | `telemetry.onboard_capacity_days`; the snapshot of an earlier run is still read |
| `supervision.watchdog_sec` | removed (no effect since 2.8.0) |
| `storage.bytes_*` | removed; `[storage]` holds `max_storage_gb`, `max_file_count` and `max_ram_gb` |
| keys retired at 1.0.0 (`simulation.test_duration_sec`, `simulation.max_storage_gb`, `physics.signal_injection_probability`, `post_processing.generate_batch_matrix`, the `[disaster]` section) | no longer recognized: `validate_config` warns that they are ignored |
| `descriptor.toml` `schema = "deepspacetelemetry-run/1"` | `"deepspacetelemetry-run/2"`: the point-wise masks are gone from the run directory |

The shipped scenarios took this form in 2.11, so a configuration derived
from one of them since 2.11 needs no change. The products of a run are
otherwise those of 2.11.
