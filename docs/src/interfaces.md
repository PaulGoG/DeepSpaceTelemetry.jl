# Analysis Interfaces

Analysis pipelines read a run through its files; nothing couples them to
the running simulation in memory. Streaming consumers follow an active run,
stationary consumers open a finished one (Two Consumer Classes, below).
Consumers may be written in any language, and any number of them may read
one run at a time.

## Design Principles

1. **Consumers are read/copy-only.** Analysis processes must never create,
   modify, move, or delete anything inside a run directory. Data a pipeline
   needs to own is copied out to consumer-managed storage.
2. **Concurrent consumers need no locks.** The event logs, `holes.csv` and
   the metrics profile are append-only; a batch directory appears by an
   atomic rename and changes afterward only by retention pruning;
   `descriptor.toml` is renamed into place whole. The other files are
   written in place: the mission-start files before the heartbeats appear,
   the post-processing products before the terminal sentinel. With rule 1
   respected no locking protocol is needed.
3. **The contract is invariant under `speed_up` and under the clock mode.**
   A consumer developed against an accelerated run (`speed_up = 3600`)
   works unchanged against a real-time run (`speed_up = 1.0`) or a tick-mode
   run (`simulation.mode = "tick"`); only the wall-clock arrival cadence
   differs. Both modes write the heartbeats and the anchor's horizon; a
   wall run adds its speed-up and nominal wall deadline. Development runs
   accelerated or on the tick clock (Reproducibility below); rehearsal runs
   at mission cadence.
4. **`config_snapshot.toml` is the only source of derived quantities.**
   Sample rates, segment/batch geometry, and session parameters are read from
   the run's own snapshot, never from the live `config.toml`.
5. **The public surface is this contract, the configuration schema, and the
   entry-point scripts.** Semantic versioning applies to those three: a
   change that alters what a consumer reads from a run directory, rejects a
   configuration that was accepted, or changes a script's arguments or
   products is a major release. A correction that brings a writer into line
   with this contract, where the contract had recorded the writer's
   deviation from it, is a defect fix, listed on the
   [Upgrading and Support](@ref) page. It comes in a minor release when it
   changes what a consumer reads from the runs of the shipped scenarios on
   the tick clock, as 3.3.0 did in moving the instants of `events_rx.csv` to the completion of
   the transfer, and in a patch release when it leaves them unchanged. The Julia modules and functions are the
   implementation and may change between minor releases; the API pages
   document them for contributors. The exception is `RunAdapter`: its public
   names are versioned with this contract.

## Two Consumer Classes

A **streaming consumer** attaches to an *active* run and reacts to
arrivals as they happen: a sliding-window search that scores every window
the moment its data are on the ground, an alert generator, an online
estimator that updates a statistic sample by sample. It owns state (what is
covered, what is pending, what is a hole), sees the data out of temporal
order, and must decide what to do with windows that may never fill.

A **stationary consumer** opens a *finished* run as a fixed record: a
post-hoc replay of the arrival stream for a latency study, a batch analysis
of the delivered series with its gaps declared, a comparison across runs. It
may read everything, including the products post-processing derives from the
record, and nothing it reads will change.

| | Streaming (active run) | Stationary (finished run) |
|---|---|---|
| Sentinel to check | `RUN_ACTIVE` present, heartbeats fresh during the mission phase | `RUN_COMPLETE` or `RUN_ABORTED`; either may close a truncated record ([Availability Window & Lifecycle Sentinels](@ref)) |
| Source of truth | `events_rx.csv`, tailed, plus the batch directories it names | the batch directories, the two event logs, `mission_profile.csv`, and everything post-processing derived from them |
| Order of the data | arrival order: the live front FIFO, the backlog LIFO behind it | any order; the record is complete |
| What can still change | new batches, `lost` and `pruned` events, a declared gap closing, the terminal sentinel | nothing |
| Gaps | holes that may close (undelivered yet) or are permanent (`lost`, a generation gap) | declared intervals with a cause |
| State | the consumer's: coverage, pending windows, horizon | none required; the mask timeline carries the live view at every snapshot |
| Read with | [Streaming Consumption](@ref) | [Stationary Analysis](@ref) |

## The Run-Directory Contract

`data/runs/<RUN_ID>/` contents, from a consumer's perspective:

| Artifact | Writer | Consumer access |
|---|---|---|
| `ground/<BATCH>/` | receiver | **Read/copy.** The delivery surface (see below). |
| `lost/<BATCH>/` | receiver | Read/copy. Retry-exhausted batches, preserved but never ground-available. |
| `events_rx.csv` | receiver (single writer) | **Tail/read.** The authoritative arrival feed. |
| `holes.csv` | receiver, emitter, and supervisor through one shared writer; post-processing settles it | **Tail/read.** The declared-hole feed: one row per hole of the delivered record, appended when the producer declares it ([Event Feeds](@ref)). |
| `events_tx.csv` | emitter; the supervisor appends the `STREAM` gap pair while the emitter is down (one live writer at a time) | Tail/read. Generation and transmission milestones. |
| `mission_profile.csv` | receiver | Tail/read. Link and buffer metrics at a change-driven cadence, columns `SimTime, WallTime, Mission_Day, Hours_Elapsed, Bandwidth_Pct, Onboard_Buffer, Link_Buffer, Ground_Total, Ground_Live, Ground_Arch, Nominal_Bandwidth_Pct, Lost_Count, Retry_Count, Disruption_Active`. |
| `masks/` | post-processing | Read/copy. Batch-state timeline, batch epochs, and the gap table. |
| `config_snapshot.toml` | pipeline (at startup) | Read. Exact run parameters and the `[provenance]` section ([Snapshot provenance](@ref)). |
| `manifest_snapshot.toml` | pipeline (at startup) | Read. The manifest of the environment the run was resolved on, with the version of every dependency; with the source identity of `config_snapshot.toml` it fixes the code state ([Source identity](@ref)). |
| `RUN_ACTIVE` / `RUN_POSTPROCESSING` / `RUN_COMPLETE` / `RUN_ABORTED` | pipeline | Read. Lifecycle sentinels (see below). |
| `clock_anchor.toml` | pipeline (at mission start) | Read. Persisted mission-clock anchor: `mode`, `wall_epoch`, `start_sim_time`, the mission end `horizon_sim`, and, for a wall-mode run, `speed_up` and the nominal wall deadline `deadline_wall` (anchors of wall runs before 2.8.0 carry no `horizon_sim`). |
| `component_events.csv` | supervisor (single writer) | Tail/read. Component lifecycle record, columns `SimTime, Component, Event`, with `Component` either `emitter` or `receiver` and `Event` `down` or `restart` (runs before 2.8.0 may also hold `stalled` and `recovered`). |
| `emitter_alive` / `receiver_alive` | the driver (heartbeats, both modes) | Read mtime. Liveness of the mission driver, not of either component: the driver touches both files together, at most once per second, from the start of the mission phase, and deletes them when it ends. Both are absent before the mission phase (setup, pre-population) and after it; a stale mtime while `RUN_ACTIVE` stands without `RUN_POSTPROCESSING` means the driver is stalled. A component outage is read from `component_events.csv`. |
| `markers.csv` | pipeline (at mission start) | Read. Event markers of the run, columns `SimTime, Label, PayloadRow` (`PayloadRow`: the payload row of the instant): the instants at which the alert-latency metric is evaluated (`alert_latency_markers.csv`). Absent when the scenario declares no markers. |
| `label_spans.csv` | pipeline (at mission start; post-processing regenerates it only when absent) | Read. Every labeled interval of the scenario on the payload grid, columns `Class, Type, Label, RowFirst, RowLast, ContentStart, ContentEnd`, rows as in `masks/gaps.csv`. `Class` is `label` (a `[[labels]]` span a payload exporter declares in payload rows), `blackout` or `recovery` (the phases of a link disruption, `Type` the event type), `generation_gap` (a scheduled generation gap as configured, `Type` the event type; the realized gap of the gap table may differ by the segment-grid snap), `contact` (`Type = pass`), `low_latency` (`Type = triggered` for a marker's period, `scheduled` otherwise), or `initial_downtime`. |
| `descriptor.toml` | post-processing (last) | Read/copy. The run's identity for a downstream collection: `schema` (`"deepspacetelemetry-run/2"` since 3.0, `/1` before), `run_id`, the producer's `package_version` and source identity (the fields of Source identity), `config_sha256`, the clock `mode`, `mission_days`, `start_sim_time`, `payload_origin`, `rng_seed`, the payload geometry (`sample_rate`, `segment_duration_sec`, `batch_size`, `points_per_batch`), `payload_columns`, the external record's `external_data_sha256` and `external_data_rows`, `written_at`, and under `[products]` the `bytes` and `sha256` of every table present; `RunAdapter.run_descriptor` returns it. Written as `descriptor.toml.partial` and renamed into place (since 3.2.0), so a reader finds the whole file or none. |
| `delivery_delay.csv` | post-processing | Read. Measurement-to-ground delay of every generated batch, columns `Batch, Live, ContentEnd, AvailableAt, Delay_Hours, LowLatency, Due` (`AvailableAt` and `Delay_Hours` missing for undelivered batches; `LowLatency` flags deliveries inside a low-latency period, also where it overlaps a nominal pass; `Due`, since 3.3.0, whether `ContentEnd` plus `post_processing.delivery_requirement_hours` falls at or before the mission end); `plots/delivery_delay.png` renders the distribution against the requirement. |
| `alert_latency.csv` | post-processing | Read. Alert-latency curves: the median and quartiles of the ground availability of the look-back data of a live event, for the realized doctrine and the counterfactual FIFO drain, columns `Lookback_Hours, N_Alerts, LIFO_Median_Hours, LIFO_Q25_Hours, LIFO_Q75_Hours, FIFO_Median_Hours, FIFO_Q25_Hours, FIFO_Q75_Hours` over the windows delivered in full under both doctrines, then, since 3.3.0, `N_Alerts_All, N_Censored_LIFO, N_Censored_FIFO, LIFO_KM_Median_Hours, LIFO_KM_Q25_Hours, LIFO_KM_Q75_Hours, FIFO_KM_Median_Hours, FIFO_KM_Q25_Hours, FIFO_KM_Q75_Hours`: the Kaplan–Meier estimates over every live event delivered under the realized doctrine, a window still incomplete at the run end censored there and one holding discarded data, or a batch lost for good under the realized doctrine, never complete (`NaN` where a quantile is not reached; [Alert-Latency Metrology](@ref)). `plots/alert_latency.png` renders the Kaplan–Meier curves. |
| `alert_latency_markers.csv` | post-processing | Read. The alert latency at every event marker, columns `Label, Marker, Batch, Lookback_Hours, LIFO_Hours, FIFO_Hours`. |
| `products.h5` | post-processing (`hdf5_export`) | Read/copy. The tabular products, the mask timeline, and the provenance attributes in one HDF5 file ([HDF5 Product Export](@ref)), without the batch payloads, the clock anchor, the sentinels and the logs; regenerable from the CSV products. |
| `plots/` | post-processing | Read/copy. Figures `mission_summary_global`, one `session_<stem>_detail` per contact (none when `post_processing.session_figures` is off; at most `session_figures_max` evenly spaced contacts when that cap is set), `alert_latency`, `delivery_delay`, and `state_raster` (the batch-state timeline as a raster), each as `.png` and `.pdf`. Every figure but `mission_summary_global` is gated by its `[post_processing]` flag, and a sweep run draws none. `scripts/postprocessing/generate_gif.jl` adds `telemetry_animation.gif` (with `--web`, `telemetry_animation_web.gif`). |
| `publication/` | post-processing (`[post_processing.publication]`) | Read/copy. Journal-width figure export (the directory is the default of `[post_processing.publication] export_dir`, which may lie outside the run directory), `<stem>__<run_id>.<format>`, with a `PROVENANCE.toml` sidecar (`[export]`: `run_id`, `run_directory`, `exported_at`, `column_width_mm`, `format`, `package_version`, `git_commit`, `git_tree_sha1`, `git_dirty`, `config_snapshot_sha256`, `figures`). |
| `masks/gaps.csv` | post-processing | Read. Every hole of the delivered record as a declared interval with its cause ([Stationary Analysis](@ref)); the first product post-processing writes. |
| `masks/telemetry_mask_timeline.csv` | post-processing (`generate_mask_timeline`) | Read/copy. The batch-state timeline: one row per metrics snapshot, one column per batch, states 0–4, described under Stationary Analysis; also the source of the HDF5 `masks/timeline` group. |
| `masks/batch_epochs.csv` | post-processing (with the mask timeline) | Read. Batch → epoch map, columns `Batch, GenSimTime, ContentEpoch, PayloadRow`: `GenSimTime` the finalization instant from the event log, `ContentEpoch` and `PayloadRow` the first-sample timestamp and payload row from the batch metadata. Written with the mask timeline (`post_processing.generate_mask_timeline` on, `mission_profile.csv` non-empty) when the run has `gen` rows. |
| `HALT` | **operator** | **The one sanctioned external write**: `touch HALT` stops both components cleanly at their next iteration; the pipeline removes the file once the components have joined, before post-processing. |
| `emitter.log`, `receiver.log`, `supervisor.log` | logger | Read. Diagnostics for a human reader, not a parsed interface: the two component logs and the supervisor's `[SUPERVISOR]`, `[POST]` and `[CONFIG]` records of the mission and its post-processing, each rotated to `<name>#k.log` at `retention.log_rotate_mb`. |
| `onboard/`, `link/` | emitter/receiver | **Off-limits.** Internal staging; the emitter counts in-flight batches from the `link/` listing, so a slot frees when the receiver moves a batch out. |

Several files exist only under a condition: `events_rx.csv` from the
receiver's first event, `holes.csv` from the first declared hole (a run
without holes has none), `component_events.csv` from the first component
failure, `manifest_snapshot.toml` when the active environment has a
manifest, `alert_latency.csv` when a live batch was delivered,
`alert_latency_markers.csv` with it when the run has markers, and
`delivery_delay.csv` when a batch was generated. A product written whole
may stand beside `#k` backups of itself (`masks/gaps#1.csv`,
`descriptor#1.toml`) once post-processing has been repeated, and
`descriptor.toml.partial` exists while the descriptor is written; neither
is part of the contract.

A batch directory contains `metadata.json` and one `seg_<id>.csv` per
segment. A segment file has one column per payload column, under its name:
the one `Amplitude` column of a synthetic run or of an external run without
`physics.external_data_columns`, otherwise the listed columns of the
external file. A synthetic run writes the flag values `0.0`
and `1.0`, an external run the ingested samples. The column names of a run
are `payload_columns` of `descriptor.toml` and, for an external run,
`external_data_columns` under `[provenance]` of the snapshot. Every column
shares the payload grid, the batches, and the link, so one hole table
covers all of them.

| `metadata.json` key | Content |
|---|---|
| `batch_id` | the global batch index `k` |
| `segment_count` | the number of segment files |
| `content_epoch` | mission timestamp of the payload's first sample: the physical epoch the data belong to |
| `payload_row` | payload row of that first sample ([Batch Identity → Sample Interval](@ref)) |
| `created_at` | mission instant at which the batch was finalized and became transmittable: the content end of its last segment, in either clock mode |
| `markers` | optional: the labels of the event markers the payload holds |

The order of the keys carries no meaning. Segment files carry no
timestamps: sample `k` of a batch lies at
`content_epoch + (k − 1) / sample_rate` and is payload row
`payload_row + k − 1`.

Instants in the CSV tables (`DeclaredAt`, `SimTime`, `WallTime`,
`GenSimTime`, `ContentEpoch`, `ContentStart`, `ContentEnd`, `AvailableAt`,
`Marker`) are written as `yyyy-mm-ddTHH:MM:SS.s`, the seconds with one to
three decimals (`2035-01-04T12:00:36.0`, `2026-09-24T02:01:17.051`). The
package fixes that form on write and the column types on read
(`TelemetryCore.write_table`, `TelemetryCore.read_table`), independent of
the defaults of the CSV library in use. Instants in `metadata.json` and in
the TOML files are written by `string(::DateTime)`, without a fraction at
whole seconds (`2035-01-04T12:00:36`).

Batches are delivered by an atomic same-filesystem `mv`: a directory visible
under `ground/` is complete, and afterward only the retention custodian
modifies it ([Availability Window & Lifecycle Sentinels](@ref)).

### Snapshot provenance

The `[provenance]` section of `config_snapshot.toml`:

| Key | Content |
|---|---|
| `config_sha256` | SHA-256 of the configuration as sorted TOML without `[provenance]`; its first eight hex digits open a generated run identifier, `RUN_cfg=<hash>_pid=<pid>_t=<yyyymmdd_HHMMSS>`; a run ID passed to `run_full_sim.jl`, or a sweep's `<prefix>_seed<seed>`, carries no hash |
| `payload_origin` | content instant of payload row 1, `start_sim_time` less `initial_downtime_days`, as an ISO-8601 string ([Batch Identity → Sample Interval](@ref)) |
| `external_data_path`, `external_data_rows`, `external_data_sha256`, `declared_sample_rate`, `external_data_columns` | identity of the input record; external data only |
| `[provenance.platform]` | `package_version`; the source identity `identity_source`, `git_commit`, `git_tree_sha1`, `git_dirty`, `repo_url`, `repo_rev` ([Source identity](@ref)); `reader_tree_sha1` (since 3.3.0); `hostname`, `os`, `cpu_model`, `logical_cores`, `total_memory_gb`, `julia_version`, `versioninfo`, `julia_threads`, `blas_threads` |

### Provenance conventions

The run directory follows the conventions of DrWatson's provenance tooling
without the dependency. Two concurrent components write the layout batch by
batch and the provenance is recorded at setup, which the whole-file
semantics of `tagsave` and `safesave` do not cover. The correspondence:

| DrWatson | This package |
|---|---|
| `savename`: parameter-derived identifier | `TelemetryCore.generate_run_id`: `RUN_cfg=<8 hex of config_sha256>_pid=<pid>_t=<yyyymmdd_HHMMSS>`, key=value fields in `savename` order |
| `tagsave`: the git commit stored with the result | `TelemetryCore.setup_run_dir`: `config_snapshot.toml` with `[provenance.platform]` (source identity, hostname, hardware, Julia and package versions) beside `manifest_snapshot.toml` |
| `safesave`: `#k` backup rotation, never an overwrite | `TelemetryCore.backup_existing` and `backup_existing_dir`: the same `<name>#k` rotation for every product written whole and for a batch directory that meets a namesake; a run directory is never reused (`setup_run_dir` refuses a non-empty one) |
| `produce_or_load`: cached expensive stages | not provided: the mission phase is a live two-component process, and every post-processing product is regenerable from the run directory by `Supervisor.post_process!` or the function of its stage |
| `datadir`, `projectdir` | `TelemetryCore.run_directory`: `<data root>/runs/<RUN_ID>`, the data root being `TelemetryCore.DATA_ROOT[]` (default: the directory named by `DEEPSPACETELEMETRY_DATA` when set, else `data/` under the package directory) |

### Source identity

A run records the identity of the package source it was made from in
`[provenance.platform]` of `config_snapshot.toml` and again in
`descriptor.toml` (since 2.6.1; `TelemetryCore.source_identity`). The
identity is defined for a git checkout and for a copy Pkg installed under
`~/.julia/packages`, which has no `.git`.

| Field | Content |
|---|---|
| `identity_source` | How the identity was determined: `work_tree` (the package directory is the top level of a git checkout, or since 3.3.0 a directory tracked in a clone of this repository, as the headless package), `manifest` (a copy installed by Pkg, matched by UUID to its entry in the manifest of the active environment), or `directory` (neither; the content of the directory alone). |
| `git_tree_sha1` | The git tree hash of the source: `HEAD^{tree}` of the checkout (`HEAD:<path>` for a tracked directory), the `git-tree-sha1` of the manifest entry, or the hash of the package directory computed as git computes it (leaving out `.git`, the untracked manifests, and, under a data root inside it, everything but the `.gitkeep` placeholders the repository tracks). Never empty. |
| `reader_tree_sha1` | The tree hash of the reader package: its tree at `HEAD` in a clean clone of this repository, otherwise the hash of its directory computed as above. The identity of the configuration and I/O layer where the package identity does not hold it, as for the headless package in a container image (since 3.3.0). |
| `git_commit` | The checkout's `HEAD`; for an installed copy, the `repo-rev` of the manifest entry when it is a full 40-digit commit hash, as in a `[sources]` pin by commit. Empty for a copy pinned by branch or tag, one installed from a registry, and a bare directory. |
| `git_dirty` | The code that ran differs from the recorded identity: uncommitted changes to tracked files of the checkout, or an installed directory whose tree hash differs from its manifest entry's (a `[RUN]` warning on the console at startup, before `supervisor.log` exists). |
| `repo_url`, `repo_rev` | The `repo-url` and `repo-rev` of the manifest entry of a copy added by URL; empty otherwise. |

`git_tree_sha1` identifies the code: with `git_dirty = false` it fixes the
source, however the package was obtained. Equal content gives an equal
value, the `git-tree-sha1` Pkg writes into a manifest and the output of
`git rev-parse <commit>^{tree}`. A non-empty `git_commit` has
`git_tree_sha1` as its tree and adds the history. `repo_url` and
`repo_rev` say where an installed copy came from and identify nothing, as
a branch or a tag moves. A downstream collection
keys a run's producer by `git_tree_sha1` and `git_dirty` and copies
`git_commit` when present. A run with `git_dirty = true` cannot be
reproduced from its recorded identity. Runs made before 2.6.1 record only
`git_commit` and `git_dirty`, with `git_commit` empty when made from an
installed copy.

## Availability Window & Lifecycle Sentinels

With `[retention]` disabled (the default), no payload is deleted from a
run directory: delivered batches persist for the run's lifetime, and only
the interactive `scripts/maintenance/cleanup.jl` deletes them.

With `retention.enabled = true`, the receiver's custodian bounds the
delivered-payload footprint: **a batch's payload is guaranteed readable for
`retention.grace_hours` of mission time after its `ingested` event**, and a
pipeline copies what it needs within that window. Beyond it, once the
payload tally exceeds `retention.high_watermark_gb`, the oldest-ingested
batches lose their `seg_*.csv` files. The batch directory remains with its
`metadata.json` and gains a zero-byte `PRUNED` marker, and a `pruned` row
(state-preserving, `Attempt = 0`) is appended to `events_rx.csv`.
Consumers must tolerate both the marker and the event value. Event logs,
metrics, masks, snapshots and `lost/` are not pruned; the replay and the
mask products read only those and the batch metadata. Retention is
time-based: a consumer registers nothing, as registering would make it a
writer.

Run lifecycle is signaled by sentinel files in the run directory.
`RUN_ACTIVE` exists while the pipeline may still write. At the end of the
lifecycle `RUN_COMPLETE` replaces it, also after a component failure, the
`abort` policy or a `HALT`: the sentinel marks the end of writing, not a
full-length record (compare the last `SimTime` of `mission_profile.csv`
with the anchor's `horizon_sim`). `RUN_ABORTED` replaces it instead when an
exception ends the pipeline. A consumer may treat either terminal sentinel
as the signal to switch from tailing to batch processing.

`RUN_POSTPROCESSING` stands beside `RUN_ACTIVE` from the moment the emitter
and the receiver have stopped until the lifecycle ends: while it is present
the payload, the event logs, and the metrics profile are final, and only
derived products (metrology tables, masks, figures, exports) are still
written. The gap table, the settled hole feed, and the metrology tables
come first; `descriptor.toml` comes last.

The terminal sentinels are written by the supervisor process as it leaves.
A process killed from outside (by the kernel's out-of-memory handler, by a
scheduler at its time limit) leaves `RUN_ACTIVE` behind with no process to
remove it. Such a directory is a stranded run: its heartbeats are
stale and nothing writes to it. It is settled with
```bash
julia scripts/postprocessing/complete_run.jl <RUN_ID>
```
which runs the post-processing again from the data on disk, with the
settings of the run's own snapshot, and replaces `RUN_ACTIVE` by
`RUN_COMPLETE` when the mission phase had ended, or by `RUN_ABORTED` when
the process died before the horizon and the record is truncated. The
mission phase counts as ended when `RUN_POSTPROCESSING` is present or,
failing that, when the `SimTime` of the last metrics row lies within 1 % of
the mission span (at least 1 s) of the anchor's `horizon_sim` (for an
anchor without one, its `WallTime` against the wall deadline).
The script refuses a wall run whose nominal deadline has not passed and,
without `--force`, a run whose top-level files or `plots/` were written to
within the last minute.

## Component Outages & Generation Gaps

The two components run under a supervisor (`[supervision]` in the config):
on a component failure the policy `abort`s the run cleanly, `continue`s
one-sided, or `restart`s the component (bounded attempts). Consumers observe
outages through `component_events.csv`. A receiver
outage acts on the record as a ground-station blackout does: the backlog
accumulates, then drains. An emitter outage is a generation gap: the
restarted instrument resumes at the first segment boundary at or after the
*current* mission time, on the sampling grid of the payload origin.

A `gap_start` / `gap_end` row pair in `events_tx.csv` bounds each of three
kinds of generation gap, told apart by `Batch`:

| `Batch` | Gap | `gap_start` | `gap_end` |
|---|---|---|---|
| `STREAM` | emitter outage | content end of the last batch finalized before the outage: the instant of row `payload_row + points_per_batch` of the highest `payload_row` stamp, or the payload origin when no batch exists | resumption instant |
| `SCHEDULED` | scheduled generation gap (a disruption event with `affects = "generation"`) | first discarded content instant | scheduled end rounded up to the segment grid |
| `RECORDER` | recorder overflow (the on-board buffer at `telemetry.onboard_capacity_days`) | first discarded content instant | content epoch of the first batch recorded again |

The rows of the partial batch the failed emitter held are lost with it and
fall inside the `STREAM` gap. The pair is written only when a replacement
emitter starts; under `on_component_failure = "continue"`, or once
`max_restarts` is exhausted, the outage is not recorded as a gap. For a
`SCHEDULED` gap, `[gap_start, gap_end)` is the content not recorded. During
a recorder overflow the instrument keeps generating and the data are
dropped on board, so the grid continues without a jump.

No gap shifts the sampling grid: segment identifiers and payload rows
continue from the content epoch, and a batch's rows come from its
`payload_row` stamp ([Batch Identity → Sample Interval](@ref)). The mask
replay treats gap events as state-preserving.

## Event Feeds

`events_rx.csv` — columns `SimTime, Batch, Event, Attempt`; `Attempt` is
populated on every row. The `SimTime` of an `ingested`, `retry` or `lost`
row is the completion instant of the transfer that resolved the batch, at
which the row is appended ([Packet Loss Channel Models](@ref)); before
3.3.0 it was the start of the transfer:

* `ingested` — the batch reached the ground archive; `Attempt` is the
  number of failed attempts before the successful transfer (`0` for a batch
  reconciled at receiver start-up). **Ordering guarantee:** the payload is
  moved into `ground/` *before* this row is appended, so a consumer that
  reads an `ingested` event may open the batch immediately.
* `retry` — a transfer attempt was lost; the batch remains on the link and
  is re-served no earlier than one round-trip light time later, other
  in-flight batches first (a restarted receiver does not keep the deferral
  and may retry at once). `Attempt` counts failed attempts so far.
* `lost` — retry budget exhausted (`Attempt` = the resolved retry limit + 1: `max_retries + 1` under `on_loss = "retransmit"`, `1` under `on_loss = "drop"`); the
  batch was moved to `lost/` (also before the row is appended) and will
  never become ground-available.
* `pruned` — the retention custodian removed the payload of a delivered
  batch (`Attempt` = `0`); the `PRUNED` marker and `metadata.json` remain
  ([Availability Window & Lifecycle Sentinels](@ref)).

`events_tx.csv` — columns `SimTime, Batch, Event`:

* `gen` — the batch was finalized on board.
* `tx` — the batch was placed on the downlink.
* `marker` — `SimTime` is an event-marker instant and `Batch` the batch
  holding it, appended when that batch is finalized; state-preserving.
* `gap_start` / `gap_end` — the pair bounding a generation gap (`Batch` =
  `STREAM`, `SCHEDULED`, or `RECORDER`, see above); state-preserving.

`holes.csv` — columns `DeclaredAt, Cause, Batch, RowFirst, RowLast,
ContentStart, ContentEnd`. `DeclaredAt` is the mission instant of the
declaration; the other columns are those of `masks/gaps.csv`. The file is
append-only, with rows in declaration order, and every writer declares at
the current mission instant, so `DeclaredAt` is non-decreasing (since
3.3.0; before, a `lost` row could precede the row above it by up to one
transfer time).

| `Cause` | Declared by | When |
|---|---|---|
| `lost`, `pruned` | receiver | at its `lost` or `pruned` row |
| `scheduled` | emitter | when it skips the gap |
| `recorder` | emitter | at the finalization of the first batch recorded again |
| `stream` | supervisor | before the replacement emitter starts |
| `undelivered`, `not_generated`, a `recorder` gap still open | post-processing | after the mission phase, with the nominal mission end as `DeclaredAt` |

A row is appended after the event row that announces the same hole, so a
consumer that reads the feed alone is never ahead of the event logs. On a
finished run the feed and the gap table hold the same holes.

## Batch Identity → Sample Interval

Batch names are `LIVE_batch_<k>` (finalized while the link is
transmittable: inside a contact window, nominal pass or low-latency period,
and outside a full blackout) or `ARCH_batch_<k>` (finalized otherwise, and
every batch of the pre-population); `k` is the global 1-based batch index.

The payload is sampled on one grid for the whole run, anchored at the
payload origin `t₀` (`[provenance] payload_origin` in
`config_snapshot.toml`): payload row `r` is the sample at
`t₀ + (r − 1) / sample_rate`. In external mode row `r` is data row `r` of the
input CSV (header excluded); rows past its end are zeros. With several
payload columns, row `r` holds one sample per column, all at the same
instant. A batch with
content epoch `e` starts at the row

```
payload_row = (e − t₀) · sample_rate + 1
```

stamped in its `metadata.json`, and holds the rows
`payload_row … payload_row + points_per_batch − 1`, with

```
points_per_batch = round(sample_rate × segment_duration_sec) × batch_size
```

(all three from `config_snapshot.toml` `[physics]`). Segment identifiers are
grid positions as well: `seg_<id>.csv` opens at
`t₀ + (id − 1) · segment_duration_sec`, so identifiers never repeat within a
run and a gap skips the identifiers of the segments it suppresses. The
mapping is row-exact when `sample_rate × segment_duration_sec` is an
integer. Otherwise validation warns, and the rows of consecutive segments
still remain consecutive and disjoint, with
`payload_row = (id − 1) · round(sample_rate × segment_duration_sec) + 1`.

Batch indices stay contiguous across generation gaps while the rows do
not: a batch's rows come from its `payload_row` stamp, which every batch
carries, not from its index. On a run whose `events_tx.csv` has no
`gap_start` row the stamp of batch `k` is `(k − 1) · points_per_batch + 1`.

## Streaming Consumption

A streaming consumer follows an active run through its arrival feed. The
loop has five parts: attach, follow the feed, maintain coverage, treat the
holes, and leave when the run ends.

**Attach.** Check that `RUN_ACTIVE` and `clock_anchor.toml` exist: the
anchor, `markers.csv` and `label_spans.csv` are written once the on-board
buffer is pre-populated, as the mission phase starts, and from then on
`receiver_alive` refreshes about once per wall second in both modes. Then
read once:

* `config_snapshot.toml`: the geometry from `[physics]` (`sample_rate`,
  `segment_duration_sec`, `batch_size`, hence `points_per_batch`), the
  mission epoch `[simulation] start_sim_time`, the instant of payload row 1
  `[provenance] payload_origin` (see [Batch Identity → Sample Interval](@ref)), and, for an
  external payload, the record length `external_data_rows`, beyond which
  the producer pads with zeros.
* `clock_anchor.toml`, if the consumer paces itself against mission time:
  `wall_epoch`, `start_sim_time` and `speed_up` give the nominal mission
  instant of a wall instant (a host that lags runs behind it), `horizon_sim`
  is the mission end and `deadline_wall` its nominal wall instant. A
  tick-mode anchor has no `speed_up` and no `deadline_wall`.
* `label_spans.csv`, present from mission start: the labeled intervals of
  the scenario on the payload grid.

**Follow the feed.** `events_rx.csv` is append-only with a single writer.
Keep the count of rows consumed and read the rows beyond it on every poll;
by the ordering guarantee ([Event Feeds](@ref)), every `ingested` batch so
read is already in `ground/`. The four event values and the consumer's
response:

| `Event` | Meaning | Response |
|---|---|---|
| `ingested` | the batch is in `ground/`; `Attempt` counts the failed transfers before it | map the batch to its rows, read its segments, extend the coverage |
| `retry` | a transfer was lost; the batch stays on the link and is re-served after one round-trip light time | none (state-preserving); it tells the consumer that the batch is coming late |
| `lost` | the retry budget is exhausted; the batch is in `lost/` and will never be on the ground | a permanent hole: discard or gap-handle the windows that cross it, never wait on it |
| `pruned` | the retention custodian removed the payload of a delivered batch; `metadata.json` and a `PRUNED` marker remain | the rows stay covered for a consumer that copied the payload within `retention.grace_hours`; otherwise a hole |

The poll interval follows the cadence of the run: one segment per
`segment_duration_sec / speed_up` wall seconds, a batch every `batch_size`
segments. Polling a few times per batch period is enough; at `speed_up = 1`
that is minutes. A tick run has no wall mapping:
arrivals come as fast as the host processes them, a consumer following one
polls as fast as it can, and a consumer is best developed against the
finished record. For a long run, tail by byte offset;
`RunAdapter.FeedCursor` does so for `events_rx.csv` and `holes.csv`.

**Maintain coverage.** Map each batch to its rows ([Batch Identity → Sample Interval](@ref))
and keep the delivered rows as a set of disjoint intervals. Arrival is out
of temporal order: live batches stream FIFO with priority, and the
blind-spot backlog backfills LIFO (newest first) behind them, so coverage
grows backward in time from each live front, contiguous behind it, session
by session. A window is evaluable when the coverage
spans it (fully, or to an acceptable fraction with the holes known).
Evaluate it once, when that first becomes true, and do not re-evaluate it
when later batches arrive behind it unless the analysis is meant to.

**Treat the holes.** A row not yet covered is in one of three states, and
the feed and the transmission log tell them apart:

* *Pending*: the batch was generated (`gen` row in `events_tx.csv`) and is
  on board or on the link. It will arrive, late; a window that needs it
  waits. The `retry` rows say how many attempts it has survived.
* *Permanent*: the batch is `lost`, or the rows were never generated: a
  generation gap bounded by a `gap_start` / `gap_end` pair of
  `events_tx.csv` ([Component Outages & Generation Gaps](@ref)). Declare the
  hole when those rows appear. `holes.csv` carries each permanent hole as
  one row when it is declared, and a consumer may tail it in place of
  pairing the rows; the pending state is read from the transmission log.
* *Unknown*: no `gen` row yet, because mission time has not reached the
  rows. Beyond the current mission instant nothing is pending.

An *order horizon* bounds how long a consumer waits for a pending batch
before scoring without it; at the horizon the pending hole becomes a
declared one. The realized arrival delays of the shipped scenarios
(`delivery_delay.csv`) are the reference for choosing it.

**Leave.** Once `RUN_POSTPROCESSING` stands, the payload, the event logs
and `mission_profile.csv` are final; once `RUN_COMPLETE` or `RUN_ABORTED`
replaces `RUN_ACTIVE`, finish as a stationary consumer. A stranded run is
settled as [Availability Window & Lifecycle Sentinels](@ref) describes. The
end-of-run rows of `holes.csv` land during post-processing: read the feed
once more after the terminal sentinel.

A minimal consumer in Julia, with the package as a reader (consumers in
other languages read the same files):

```julia
using DeepSpaceTelemetry: TelemetryCore

segment_files(dir) = sort(
    filter(f -> occursin(r"^seg_\d+\.csv$", f), readdir(dir));
    by = f -> parse(Int, match(r"\d+", f).match),
)
read_payload(dir) = reduce(vcat, (TelemetryCore.load_segment(joinpath(dir, f)).data for f in segment_files(dir)))  # samples × columns

function follow_run(run_id; poll_seconds = 5.0)
    run_dir = TelemetryCore.run_directory(run_id)
    cfg = TelemetryCore.load_run_config(run_dir)
    phys = cfg["physics"]
    points_per_batch = round(Int, phys["sample_rate"] * phys["segment_duration_sec"]) * phys["batch_size"]
    covered = UnitRange{Int}[]            # delivered payload rows
    holes = Pair{UnitRange{Int},Symbol}[] # permanent holes with their cause
    consumed = 0
    rx_path = joinpath(run_dir, "events_rx.csv")  # absent until the first arrival
    while true
        finished = !isfile(joinpath(run_dir, "RUN_ACTIVE"))  # tested before the read
        rx = isfile(rx_path) ? TelemetryCore.read_table(rx_path) : nothing
        for row in (rx === nothing ? () : eachrow(rx[(consumed + 1):end, :]))
            consumed += 1
            row.Event == "retry" && continue  # the batch is still under link/
            stage = row.Event == "lost" ? "lost" : "ground"
            meta = TelemetryCore.read_batch_metadata(joinpath(run_dir, stage, row.Batch))
            row_first = meta["payload_row"]
            rows = row_first:(row_first + points_per_batch - 1)
            if row.Event == "ingested"
                payload = read_payload(joinpath(run_dir, "ground", row.Batch))
                push!(covered, rows)          # feed `payload` at `rows` to the analysis
            elseif row.Event == "lost"
                push!(holes, rows => :lost)
            elseif row.Event == "pruned"
                push!(holes, rows => :pruned)
            end
        end
        finished && break
        sleep(poll_seconds)
    end
    return covered, holes
end
```

The generation gaps enter the same `holes` list from `events_tx.csv`: each
`gap_start` row with `Batch` in `STREAM`, `SCHEDULED`, or `RECORDER` opens a
hole at the row of its instant, closed by the matching `gap_end` (the
conversion between an instant and a payload row is in
[Batch Identity → Sample Interval](@ref)).

**The run adapter.** `RunAdapter` reads a run directory through the files
above. A consumer in Julia calls it; a consumer in another language can
take it as the reference reader:

```julia
using DeepSpaceTelemetry: RunAdapter

run = RunAdapter.open_run("RUN_ID")           # a path or an identifier; checks the producer's version
RunAdapter.run_geometry(run)                 # sample rate, segment length, batch size, payload origin, record length, clock mode
RunAdapter.list_batches(run)                 # per batch: name, index, live?, payload rows, content epoch,
                                             #            state ∈ :ground | :lost | :pruned
RunAdapter.batch_record(run, "LIVE_batch_7") # the same record for one batch, from its metadata alone; nothing if absent
RunAdapter.read_batch(run, "LIVE_batch_7"; column = 1)   # one payload column, Float32, segments in ascending id (read_batch_matrix: all columns)
RunAdapter.read_batch_matrix(run, "LIVE_batch_7"; delivered = true)   # refuses a batch not on the ground (lost, pruned, absent)
RunAdapter.arrival_events(run; after = n)    # the feed beyond the n rows already consumed, in mission-time order
RunAdapter.delivered_rows(run; at = t)       # the payload rows on the ground at mission instant t, as disjoint intervals
RunAdapter.run_state(run)                    # :active | :complete | :aborted, from the sentinels
RunAdapter.run_descriptor(run)               # descriptor.toml as a Dict (empty until post-processing writes it), schema checked
RunAdapter.markers(run)                      # the event markers with their payload row
RunAdapter.label_spans(run)                  # the labeled intervals of the scenario, with their rows
RunAdapter.declared_holes(run; after = n)    # the producer's hole feed beyond n rows, each with its declaration instant
cursor = RunAdapter.FeedCursor(run, :arrivals)   # or :holes; each call below reads only the bytes appended since the last
RunAdapter.arrival_events(cursor)            # (declared_holes(cursor) for a :holes cursor)
```

`open_run` refuses a run of a producer older than 2.6.0, the first with
the declared-hole feed and the label-span table, unless told otherwise
(`minimum_version`). `declared_holes` reads `holes.csv`: a streaming
consumer learns of a permanent hole when the producer declares it, and on a
finished run the feed also holds the end-of-run causes of `masks/gaps.csv`.
A consumer following the arrival feed resolves each batch with
`batch_record`, which reads that batch's metadata alone (`list_batches`
reads every batch), and reads its payload with `delivered = true`; without
it, `read_batch` and `read_batch_matrix` also serve a lost batch from
`lost/`, for diagnostics. The
adapter ships in the reader package `DeepSpaceTelemetryReader`
(`Pkg.add(url = …, subdir = "reader")`), which a consumer adds without the
figure stack.

The adapter's types (`RunHandle`, `RunGeometry`, `BatchRecord`,
`ArrivalEvent`, `Hole`, `FeedCursor`), its version floor
`MINIMUM_PRODUCER_VERSION`, and the functions above with `batch_rows`,
`record_final`, `row_time` and `time_row` are declared `public` and not
exported: a consumer qualifies them, as in the example. Principle 5
versions them with this contract; the changelog gives the release of each.

**Streaming archetypes.** The loop above is what a *streaming engine* does
generically: a coverage set, a window scheduler that emits each window
once, conditioning on the delivered stretch, a scorer, and an ordered
commit with an order horizon for stateful estimators. Such an engine is
best kept behind the adapter, which serves its follow mode on an active
run and its replay mode on a finished one. A *detector* (a classifier, a
matched filter) then scores the conditioned windows. An *online estimator*
that requires strictly increasing sample times fits the live FIFO front
only; the LIFO backfill behind it is out of order for such a consumer and
is better analyzed from the finished record.

## Stationary Analysis

A stationary consumer opens a finished run (`RUN_COMPLETE` or
`RUN_ABORTED`) and reads a fixed record. A run that `run_mission` closed
with `RUN_ABORTED` ended before post-processing: it carries no gap table,
no settled `holes.csv` and no `descriptor.toml`, and `complete_run.jl`,
which settles only a directory still holding `RUN_ACTIVE`, does not derive
them. Three views of the same record serve different questions.

**The delivered series.** Concatenate the ground batches on the payload
grid: batch rows from `payload_row` (`masks/batch_epochs.csv` tabulates
`Batch, GenSimTime, ContentEpoch, PayloadRow` for every generated batch),
samples from the segment files, and `missing` wherever no delivered batch
covers a row. Post-processing writes the holes, each with a cause, as
`masks/gaps.csv`: columns `Cause, Batch, RowFirst, RowLast, ContentStart,
ContentEnd`, one row per hole, sorted by `RowFirst`. `RowFirst` and
`RowLast` are payload rows, both inclusive; `[ContentStart, ContentEnd)` is
the content interval. `holes.csv` and `label_spans.csv` share this row
convention. Up to the last row of the last generated batch (for an
external payload, up to `external_data_rows`), the rows of the table and
the rows no delivered batch covers are the same set. Rows of a synthetic
run after its last generated batch, such as the partial batch at the
horizon or the rest of a mission whose emitter outage was not recorded as
a gap, appear in neither. The causes and where the record declares each:

| `Cause` | Where it is declared | Rows |
|---|---|---|
| `lost` | `events_rx.csv` row `lost`; the batch in `lost/` with its metadata | its `payload_row … + points_per_batch − 1` |
| `pruned` | `events_rx.csv` row `pruned`; the `PRUNED` marker in `ground/<BATCH>/` | the same |
| `stream`, `scheduled`, `recorder` | `gap_start` / `gap_end` pair in `events_tx.csv` (`STREAM`, `SCHEDULED`, `RECORDER`); a gap still open at run end closes at the mission end | the rows between the two instants |
| `undelivered` | a `gen` row in `events_tx.csv` with no `ingested` or `lost` row; the batch directory under `onboard/` or `link/` | its `payload_row … + points_per_batch − 1` |
| `not_generated` | external payload only, no `gen` row: the mission ended before the record was exhausted | the rows past the last generated batch, up to `external_data_rows` |
| none (beyond the record, not a row of the table) | `external_data_rows` in `[provenance]` (external payload) | every row past it holds the producer's zero padding |

`holes.csv` holds the same rows on a finished run, each with its
declaration instant ([Event Feeds](@ref)): read the feed for the declaration
history, `masks/gaps.csv` for the table. The table is the reference:
post-processing settles the feed from it and reports in the run log any row
of the feed the table does not derive (`Masks.hole_feed_excess`) and alters
neither file.

A gap-aware statistic takes the holes as declared intervals rather than
inferring them from the spacing of the delivered samples: the spacing cannot
tell a lost batch from an undelivered one, and cannot see a gap before the
first or after the last delivered sample.

```julia
using DeepSpaceTelemetry: TelemetryCore

run_dir = TelemetryCore.run_directory("RUN_ID")
cfg = TelemetryCore.load_run_config(run_dir)
phys = cfg["physics"]
points_per_batch = round(Int, phys["sample_rate"] * phys["segment_duration_sec"]) * phys["batch_size"]

holes = TelemetryCore.read_table(joinpath(run_dir, "masks", "gaps.csv"))
rx = TelemetryCore.read_table(joinpath(run_dir, "events_rx.csv"))
first_row = TelemetryCore.batch_payload_rows(run_dir)      # every generated batch, all stages
delivered = setdiff(Set(rx.Batch[rx.Event .== "ingested"]), Set(rx.Batch[rx.Event .== "pruned"]))

n_rows = max(
    maximum(holes.RowLast; init = 0),
    maximum((first_row[name] + points_per_batch - 1 for name in delivered); init = 0),
)
# one column; a multi-column run fills a samples × columns matrix from load_segment(...).data
series = Vector{Union{Missing,Float32}}(missing, n_rows)
for name in delivered
    payload = vec(read_payload(joinpath(run_dir, "ground", name)))   # as in the streaming example
    r = first_row[name]
    series[r:(r + length(payload) - 1)] .= payload
end
```

`series` is the stationary record and `holes` its declared gaps with
causes, each row the interval `RowFirst:RowLast` on the same grid.
`Masks.gap_table(run_dir)` computes the same table from the record.

**The arrival stream, replayed.** For a latency study, replay
`events_rx.csv` in `SimTime` order as the arrival stream and drive the same
consumer logic as in Streaming Consumption. The framework's own mask
products are computed from this event log, so the replayed availability is
exactly what a live consumer saw. A streaming analysis is developed and
regression-tested this way against recorded runs before it follows a live
one, and two routing rules or two link models are compared on the same
arrival logic.

**The prepared products.** Post-processing derives from the record the
views most analyses want and that need no replay of one's own:

* `masks/telemetry_mask_timeline.csv`: one row per snapshot instant
  (`SimTime`, one per `mission_profile.csv` row), columns `Batch_<k>` for
  every batch identifier up to the largest generated, values `0 = Future`,
  `1 = Onboard`, `2 = Link`, `3 = Ground`, `4 = Lost`. A window anchored at
  snapshot `r` may use the batches with state 3 in row `r`, the live view of
  a streaming consumer at that instant.
* `masks/gaps.csv`: the holes of the delivered record with their causes,
  as above; `masks/batch_epochs.csv`: the batch → epoch and payload-row
  map.
* `mission_profile.csv`: link capacity, on-board and link buffers, the
  cumulative ground counts, losses and retries at a change-driven cadence.
* `delivery_delay.csv`: the measurement-to-ground delay of every generated
  batch, `missing` for the undelivered.
* `alert_latency.csv` and `alert_latency_markers.csv`: the completion of
  the look-back window after a live event, realized against the FIFO
  counterfactual, and at every marker.
* `markers.csv` and `label_spans.csv`: the event markers, and the labeled
  intervals of the scenario with the `[[labels]]` spans.
* `products.h5`: all of the above in one file ([HDF5 Product Export](@ref)).

**Reproducibility.** `config_snapshot.toml` (the parameters, the source
identity, the platform) and `manifest_snapshot.toml` fix the code and the
environment of a run; the seeded scenario fixes the loss draws. Two runs of
the same scenario, mission span and seed on one platform write
byte-identical event logs, mask timeline, and batch epochs, and metrics
profiles that differ only in the wall-clock column, in either clock mode:
pacing changes when a wall run writes its rows, not what they hold.

**Stationary archetypes.** A *replay engine* consumes a finished run through
the same adapter as its streaming counterpart, in replay mode. A *batch
inference* runs on the finished record with its holes declared; a training
stage usually wants a gapless record, an inference stage tolerates a gapped
one. A *gap-aware statistic* takes the series and the declared holes and
classifies every quantity that spans a hole as exact, gap-crossing, or
censored; the `holes` of the example above are its input.

**Ensembles.** A stationary study over seeds or parameters starts from a
sweep (`scripts/run_sweep.jl`, the Sweeps module): the same configuration
on the tick clock once per seed, and the realized totals of all runs in one
table with the sweep's own provenance (Ensembles and Sweeps in the usage
page). Sweep runs skip the mask timeline, so they
carry no `masks/telemetry_mask_timeline.csv` or `masks/batch_epochs.csv`.

## HDF5 Product Export

With `post_processing.hdf5_export = true` (or
`scripts/postprocessing/export_hdf5.jl [RUN_ID]` afterward) the run's
products are also written into `products.h5`, one self-describing file for
HDF5 pipelines. The CSV products remain the primary interface; the file is
a derived view of them, regenerable at any time.

| Group | Content |
|---|---|
| root attributes | `format_version` (`"1"`, unchanged at 3.0 when the `masks/pointwise` group of 2.x files was removed), `run_id`, `start_sim_time`, `speed_up` (`NaN` for a tick run), `exported_at`, the platform fingerprint of the run snapshot (`hostname`, `package_version`, `git_commit`, `git_tree_sha1`, `julia_version`, …), `config_snapshot` (the run's configuration as TOML text), and `config_source` (`snapshot`; files written by earlier versions may hold `fallback`, meaning the project `config.toml` stood in for a missing or corrupt snapshot) |
| `events/tx`, `events/rx`, `holes` | the event logs and the declared-hole feed, one dataset per column |
| `metrics/mission_profile` | the metrics profile, one dataset per column |
| `masks/timeline` | `states` — the batch-state matrix laid out as `states[snapshot, batch]` for C-order readers (h5py, NumPy; Julia reads the transpose), `batch_id`, the snapshot instants (`SimTime`, `SimTime_iso`), and the attributes `state_codes` and `layout` |
| `masks/batch_epochs` | the batch → epoch map, `PayloadRow` included |
| `masks/gaps` | the gap table, every hole of the delivered record with its cause |
| `metrology/alert_latency`, `metrology/alert_latency_markers`, `metrology/delivery_delay` | the metrology tables |
| `markers`, `label_spans`, `component_events` | the event markers, the labeled intervals of the scenario, and the component lifecycle record |

Column conventions:

| CSV column | HDF5 dataset | Missing value |
|---|---|---|
| `DateTime` | `Float64` seconds since `start_sim_time` (attribute `unit`), with an ISO-8601 twin `<name>_iso` written by `string(::DateTime)` | `NaN`; `""` in the twin |
| boolean | `UInt8` | `0xff` |
| integer | `Int64`, or `Float64` when a value is missing | `NaN` |
| other number | `Float64` | `NaN` |
| other | string | `""` |

Each table group carries the attributes `source` (the CSV it was read
from) and `rows`; `masks/timeline` carries `source`, `state_codes`, and
`layout`.

## Real-Time Operation

`speed_up = 1.0` is a supported configuration (validation requires only
`speed_up > 0`): the mission clock then advances at wall-clock rate, one
segment per `segment_duration_sec` of real time. A run executes in one
process without checkpoint or resume, so a real-time rehearsal is planned
as a bounded campaign, such as one session or one disruption window at 1×.
