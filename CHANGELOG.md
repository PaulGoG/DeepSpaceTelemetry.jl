# Changelog

Notable changes to DeepSpaceTelemetry. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [3.1.0] - 2026-10-31

### Added
- `Masks.hole_feed_excess(run_dir)`: the rows of `holes.csv` the gap table
  does not derive, a hole the table lacks or a repeat of a held one.
  Post-processing reports a non-empty excess as a warning in the run log
  after settling the feed; the table remains the reference and neither file
  is altered. The suite asserts an empty excess on a finished run.

### Changed
- `Masks.write_gap_table` and `Masks.settle_hole_feed!` accept the derived
  table through the `table` keyword; post-processing derives it once for
  the table, the settlement and the check. The products are unchanged.

## [3.0.1] - 2026-10-29

### Changed
- A sweep runs its members concurrently as tasks on the Julia threads
  (`Sweeps.run_sweep(...; workers)`), no longer on worker processes:
  `Distributed` is no longer a dependency, and `scripts/run_sweep.jl
  --workers N` restarts itself once with `--threads=N` when Julia was
  started with fewer. A run shares no mutable state with its siblings, so
  the products are those of the serial sweep; the suite asserts it.
- `TelemetryCore.simulation_settings` reads the `[simulation]` scalars in
  one place for the mission plan, the post-processing plan and
  `validate_config`; `storage_budget` and `retention_settings` enforce their
  own bounds, so an accessor no longer accepts a value the validator
  rejects. The error messages are unchanged.
- A run without a console (`orig_stdout = devnull`, as in a sweep) draws no
  progress bar during the pre-population.
- The suite checks that every shipped scenario validates without an
  unrecognized key.

## [3.0.0] - 2026-10-28

The removals announced in 2.7.0 and 2.11.0. From here on the package is
maintained rather than extended: the manual's Upgrading and Support page
states the policy and lists the changes from 2.x.

### Removed
- The point-wise masks: `post_processing.expand_to_pointwise_masks`,
  `target_event_rows`, `masks/pointwise_mask_*.csv`, the HDF5 group
  `masks/pointwise/`, `Masks.expand_pointwise_mask`,
  `Supervisor.expand_pointwise_masks!`, `Export.write_pointwise_masks!`,
  `TelemetryCore.normalize_target_rows` and `mask_timeline_rows`, the
  estimator term, and the scripts `apply_telemetry_mask.jl` and
  `standalone_mask_expander.jl`. `RunAdapter.delivered_rows` replaces them.
- `RunAdapter.GapTracker`, `declare!` and `open_gaps`, and the derivation of
  holes from the event logs for a run without `holes.csv`.
- `supervision.watchdog_sec` and the `storage.bytes_*` calibration overrides;
  the constants are `TelemetryCore.STORAGE_CALIBRATION`.
- The readers of pre-2.6 producer output: the batch-index rows of a batch
  without a `payload_row` stamp (an error now), the `PayloadRow`-less
  `markers.csv`, the pre-0.10 `Ground_Archive` profile column
  (`TelemetryCore.normalize_profile!`), and the manifest format before Julia
  1.7.
- The 1.0.0 entries of `REMOVED_CONFIG_KEYS` and the `[disaster]` section
  check: such keys are now unrecognized and ignored with a warning.

### Changed
- `RunAdapter.MINIMUM_PRODUCER_VERSION` is 2.6.0, the first producer with
  `holes.csv` and `label_spans.csv`.
- `validate_config` rejects the keys removed here, naming the remedy; the
  accessors still read them from the snapshot of an earlier run, so
  `storage.onboard_capacity_days` of a 2.x snapshot is honoured.
- `descriptor.toml` carries `schema = "deepspacetelemetry-run/2"`.
- `TelemetryCore.supervision_settings` returns `on_component_failure` and
  `max_restarts` only.

## [2.11.0] - 2026-10-28

The last minor release before 3.0: everything 3.0 removes warns here, and
the replacements are in place.

### Added
- `RunAdapter.delivered_rows(run; at)`: the payload rows on the ground at a
  mission instant, the rows of every batch ingested by then (pruned ones
  included) merged into disjoint intervals. The rows come from the
  `payload_row` stamps, so they are exact across generation gaps; on a run
  without gaps the final point-wise mask is 1 exactly on them.
- `telemetry.onboard_capacity_days`, the new place of the recorder size.

### Changed
- The shipped scenarios and `config.toml` take their 3.0 form: no
  point-wise mask keys (their runs no longer write
  `masks/pointwise_mask_final.csv`), no `supervision.watchdog_sec`, and
  `onboard_capacity_days` under `[telemetry]`. Defaults are unchanged; a
  configuration written for 2.10 runs as before.
- Sweeps remove the point-wise mask keys from their member configurations
  instead of setting them to `false`.

### Deprecated
- The point-wise masks: `post_processing.expand_to_pointwise_masks`,
  `target_event_rows`, `masks/pointwise_mask_*.csv` and their HDF5 group,
  `Masks.expand_pointwise_mask`, `scripts/postprocessing/apply_telemetry_mask.jl`
  and `standalone_mask_expander.jl`. They place batch `k` at row
  `(k − 1) · points_per_batch + 1`, which is wrong after the first
  generation gap; use `RunAdapter.delivered_rows`. `validate_config` warns
  when either key is present, and both scripts print a notice.
- `supervision.watchdog_sec`, which has had no effect since 2.8.0.
- `storage.onboard_capacity_days`: still read, with a warning; giving it in
  both `[storage]` and `[telemetry]` is an error.
- Runs of producers before 2.6.0 (no `holes.csv`, no `label_spans.csv`):
  `RunAdapter.open_run` warns, as 3.0 refuses them by default.

## [2.10.0] - 2026-10-28

### Added
- `RunAdapter.FeedCursor(run, :arrivals | :holes)`: a byte-offset cursor
  over `events_rx.csv` or `holes.csv`. `arrival_events(cursor)` and
  `declared_holes(cursor)` return the rows appended since the previous call
  and leave a line still being written for the next one, so following a
  feed costs O(new rows) per poll instead of a re-read of the whole file.
  The `after` forms are unchanged.
- `Supervisor.run_mission(cfg; data_root)` and
  `TelemetryCore.setup_run_dir(run_id; data_root)` place a run under a
  given data root; `TelemetryCore.run_directory(run_id, data_root)`.

### Changed
- The components take their run directory, not a run ID:
  `Emitter.pre_populate(instrument, start, run_dir)`,
  `Emitter.run_emitter(clock, link, run_dir, instrument)` and
  `Receiver.run_receiver(clock, link, run_dir)` require an absolute path
  and reject a bare run ID. `TelemetryCore.DATA_ROOT` is only the default
  of the entry points, and a sweep no longer reassigns it: with
  `workers = 0` it used to stay pointed at the sweep's data root after
  `run_sweep` returned.
- The receiver reads the number of batches on board from the emitter, which
  keeps the count in step with every write to and move out of `onboard/`,
  instead of listing `onboard/` with one `stat` per batch on every loop
  iteration; it lists `link/` once per iteration instead of twice. A
  recorder at capacity holds about two thousand batches, so long and
  saturated missions spend less time in directory scans. Products are
  unchanged.
- The precompile workload runs a short tick mission end to end, figures
  included, in a temporary data root, so the component loops, the event
  writers, the post-processing tables and the figure stage are compiled at
  installation rather than in every run. The first mission of a process
  (the smoke scenario on the tick clock) completes about 24 s sooner
  without figures and about 50 s sooner with them, at the cost of a longer
  precompilation.
- A component log whose rotation or write fails drops the record with a
  line on `stderr` instead of failing the component.
- Internal deduplication without change to any product: the batch
  finalization and the recorder ceiling shared by the pre-population and
  the emitter loop, the loop exit test of both components
  (`TelemetryCore.loop_should_stop`), the receiver's re-attach state,
  retention custodian and status panel as functions of their own, one
  `decorate_axis!` for the event layers of the five time axes, the legend
  rows of the shaded windows as a table, and single definitions of the
  Gilbert–Elliott stationary loss rate and of the payload-column lookup.

## [2.9.0] - 2026-10-26

### Changed
- `TelemetryCore` and `RunAdapter` move into a second package in this
  repository, `DeepSpaceTelemetryReader` under `reader/`, which depends on
  CSV, DataFrames, JSON, TOML, SHA and the standard library only.
  DeepSpaceTelemetry depends on it by path and re-exports both modules, so
  every qualified name (`DeepSpaceTelemetry.TelemetryCore.…`) is unchanged
  and `Pkg.add(url = …)` of the main package still resolves (Pkg collects
  the `[sources]` of a package added by URL). A consumer that only reads
  run directories adds the reader alone, `Pkg.add(url = …, subdir =
  "reader")`, and no longer loads CairoMakie and HDF5. The two packages
  carry one version number. `TelemetryCore.PROJECT_ROOT` is a `Ref` set by
  the host package; `DeepSpaceTelemetry` points it at its own root.

## [2.8.0] - 2026-10-26

### Changed
- One execution model. Wall mode is the tick driver with pacing: before
  releasing a component wakeup at mission instant `t`, the driver sleeps
  until `speed_up` mission seconds per wall second have elapsed since the
  start, for the span `speed_up · mission_wall_seconds`; a host that lags
  releases late and finishes later with the same content. A wall run now
  reproduces the tick run of the same configuration to the byte, and the
  suite asserts it. The components no longer run as threads: one thread
  suffices, and the `--threads=3` advice and the thread advisory are gone.
- Heartbeats in both modes: the driver refreshes `emitter_alive` and
  `receiver_alive` at most once per second, during a pacing sleep as well,
  and removes them when the mission phase ends. `clock_anchor.toml` always
  carries `mode`, `wall_epoch`, `start_sim_time` and `horizon_sim`; a wall
  run adds `speed_up` and the nominal `deadline_wall`. A stranded run counts
  as ended when its last metrics row reaches the horizon (runs made before
  2.8.0 keep the wall-deadline rule).
- The tests of the component loops drive the tick clock directly and assert
  exact counts; the gates that tolerated a slow host are gone.

### Removed
- The wall clock type and its machinery: `SimulationClock`, `due_wall_time`,
  the compile warm-up, the threaded `supervise!` with its heartbeat watchdog
  (`stalled`/`recovered` are no longer written to `component_events.csv`),
  the pacing warnings of `validate_config`, the sleep floor, the lag
  telemetry, the `thread_advisory`, and the `deadline`/`heartbeat_path`
  keywords of `run_emitter` and `run_receiver`. `FileWatching` is no longer
  a dependency.

## [2.7.0] - 2026-10-26

### Changed
- `season_peak_day_of_year` is 89 in every scenario. The former 172 had no
  source in the Definition Study Report; a constellation trailing Earth by
  20 degrees sits about 80 degrees east of the Sun, its geocentric
  declination peaks near day 89, and the daily pass of a northern 35 m
  station (Cebreros) is longest there. The reference scenario
  `recovery_12h_seasonal.toml` (and `config.toml`) starts on 30 March 2035
  instead of 21 June, so its passes are still 12 hours, and its marker
  moves with it; its run is unchanged to the byte, since only the phase
  matters. `long_30d_seasonal.toml` starts on 20 July instead of 1 March,
  its exceptions and markers shifted by the same 141 days, so that its
  passes stay in the 8 to 9 hour range that drives the backlog to the
  recorder ceiling inside the contact gap; its totals change and its
  gallery figures are regenerated.
- The batch-state replay streams: `Masks.replay_batch_states` applies the
  event logs row by row into one state vector per batch, and
  `generate_telemetry_masks` writes `masks/telemetry_mask_timeline.csv` from
  that stream, byte-identical to before, with memory proportional to the
  batch count instead of rows times batches. `reconstruct_batch_states` and
  `batch_states` take `rows` and return records for those rows only; the
  animation requests its frame rows. Within a category the batch
  identifiers are now sorted, which moves a few anti-aliased pixels of the
  animation where markers overlap.
- The row rules of a hole are defined once, `TelemetryCore.batch_hole_rows`
  and `TelemetryCore.gap_hole_rows`, and used by the hole feed, the gap
  table and the run adapter. `RunAdapter.declared_holes` derives the holes
  from the event logs when a run has no `holes.csv` (producers before
  2.6.0), with `declared_at` missing.

### Deprecated
- `RunAdapter.GapTracker`, `declare!` and `open_gaps`: `declared_holes`
  serves both kinds of run; the tracker warns on construction and is
  removed in 3.0.
- The `storage.bytes_*` estimator-calibration overrides: still applied, with
  one `[CONFIG]` warning; removed in 3.0, when `[storage]` keeps
  `max_storage_gb`, `max_file_count`, `max_ram_gb` and
  `onboard_capacity_days`. The configuration files no longer list them.
- The metrology tables `alert_latency.csv`, `alert_latency_markers.csv` and
  `delivery_delay.csv` are written by their own post-processing stage,
  before any figure, whatever the figure flags say
  (`Metrology.write_metrology_tables`). Sweep runs draw no figure at all:
  `Supervisor.run_mission(cfg; figures = false)` skips the figure stages
  and the publication export, as the manual had stated.
- A run directory whose `config_snapshot.toml` is missing or unparsable is
  refused with a `[CONFIG]` error. Post-processing no longer falls back to
  the package's `config.toml`, which re-parametrized the products of a
  damaged run; the HDF5 attribute `config_source` is always `snapshot`.
- `component_events.csv` is written through the package's table writer, so
  its instants carry the documented form.
- Documentation and docstrings: each guarantee stated once and where it
  belongs; corrections against the code and the LISA Definition Study
  Report (catch-up ratio, light time, Kleinrock volume, section numbers,
  the seasonal peak day as a scenario phase); the contract page matches the
  writers (tick runs without heartbeats, the anchor keys, the
  post-processing order, the conditional `masks/batch_epochs.csv`, the
  `STREAM` pair only on a restart); the streaming example runs as a script.

### Fixed
- The suite runs inside one enclosing testset, asserts that no
  post-processing stage logged an error after a mission, derives the JET
  target modules from the package (RunAdapter and Sweeps were missing), and
  runs Aqua's persistent-tasks check on every CI leg but the coverage leg.
  The CI jobs carry timeouts, and the cache action may prune.


## [2.6.2] - 2026-10-14

### Added
- `RunAdapter` declares its names `public` (they are not exported):
  `RunHandle`, `RunGeometry`, `BatchRecord`, `ArrivalEvent`, `Hole`,
  `GapTracker`, `MINIMUM_PRODUCER_VERSION`, `open_run`, `run_geometry`,
  `run_state`, `record_final`, `list_batches`, `batch_rows`, `read_batch`,
  `read_batch_matrix`, `arrival_events`, `markers`, `label_spans`,
  `declare!`, `open_gaps`, `declared_holes`, `row_time`, `time_row`. A
  consumer's qualified access to the adapter now passes ExplicitImports'
  `check_all_qualified_accesses_are_public` without an ignore list. The
  module itself was already public through the package's export list.

## [2.6.1] - 2026-10-14

### Fixed
- A run made from a copy of the package installed by Pkg, the way a
  downstream consumer obtains it (`[sources]` or `Pkg.add(url = …)`),
  recorded an empty `git_commit` in `config_snapshot.toml` and
  `descriptor.toml`: the installed tree has no `.git`. Every run now records
  the identity of its source however the package was installed:
  `git_tree_sha1`, the git tree hash of the source (`HEAD^{tree}` of a
  checkout, the `git-tree-sha1` of the manifest entry of an installed copy,
  or the hash of the directory), never empty; `git_commit` of an installed
  copy from the manifest's `repo-rev` when that is a full commit hash;
  `repo_url` and `repo_rev` of the manifest entry; and `identity_source`
  (`work_tree`, `manifest` or `directory`). `git_dirty` also flags an
  installed copy modified after installation. The interfaces page states
  which fields are authoritative. The publication sidecar records
  `git_tree_sha1` and `git_dirty`, and `sweep.toml` the full identity.
- A package directory inside another git repository, such as an installed
  copy under a version-controlled depot, was given that repository's
  commit. Git is now consulted only for a directory that is itself the top
  level of a work tree.
- `manifest_snapshot.toml` is the manifest that Julia's code loading resolves
  for the active project, including a workspace root's manifest, a
  `manifest` key and `JuliaManifest.toml`; a run in a workspace member's
  environment previously recorded no manifest.

## [2.6.0] - 2026-10-13

### Added
- `label_spans.csv`, written at mission start beside `markers.csv`: every
  labeled interval of the scenario on the payload grid, columns `Class,
  Type, Label, RowFirst, RowLast, ContentStart, ContentEnd` with the row
  convention of the gap table — the `[[labels]]` spans a payload exporter
  declares in payload rows, the blackout and recovery phases of the link
  disruptions, the scheduled generation gaps as configured, the contact
  passes, the low-latency periods, and the initial downtime. Post-processing
  regenerates it only when a run lacks it. Registered in the descriptor
  and the HDF5 export; `RunAdapter.label_spans` reads it.
- The `[[labels]]` configuration section (`label`, `label_start_index`,
  `label_end_index`, inclusive payload rows), validated on load, and the
  free-form `[payload]` section for the provenance a payload exporter
  records, accepted like `[provenance]`.
- `holes.csv`, the declared-hole feed: an append-only table at the run
  root with the columns of the gap table behind `DeclaredAt`, the mission
  instant of the declaration. The receiver appends a lost or pruned batch
  as it declares it, the emitter a scheduled gap when it skips it and a
  recorder gap when the buffer has room again, the supervisor an emitter
  outage before the replacement starts; post-processing settles the feed
  from the gap table, so a finished run's feed and `masks/gaps.csv` hold
  the same holes. A consumer in any language tails one file;
  `RunAdapter.declared_holes` reads it with a cursor and `Hole` carries
  `declared_at`. Registered in the descriptor and the HDF5 export.
- `TelemetryCore.open_recorder_gap_start`, the instant of an open
  recorder gap.
- `physics.external_data_columns`: the columns of the external file to
  ingest, in that order, as one payload under one link accounting — one
  batch, one transfer, one loss draw for every column. Segment files carry
  one column per payload column under its name; the resolved names are
  `external_data_columns` in the provenance and `payload_columns` in the
  descriptor; `RunGeometry.columns`, `read_batch(; column)` and
  `read_batch_matrix` read them. A one-column run is byte-identical to
  2.5.0 (`Amplitude`, or else the first column, written as `Amplitude`).
  The storage estimate scales the payload with the column count.

### Changed
- The instant-to-row conversion of the gap table, the markers, and the
  adapter is single-sourced in `TelemetryCore` (`payload_row_time`,
  `payload_time_row`, `payload_origin`, `mission_epoch`, `mission_end`);
  every result is unchanged.
- The storage estimate counts one declared-hole row per batch.
- `DataSegment` holds a samples × columns `Matrix{Float32}` and the column
  names; the vector form remains as a one-column constructor, and
  `load_segment(...).data` of a one-column file is an n × 1 matrix.

### Fixed
- The `STREAM` gap of an emitter restart opened at the largest `SimTime`
  of `events_tx.csv`, a finalization or transmission instant, which left
  the rows of the failed emitter's partial batch in no batch and no gap.
  It opens at the content end of the last finalized batch, from the
  `payload_row` stamps, or at the payload origin when no batch exists;
  the gap table of a restarted run covers every row no delivered batch
  does, which the suite now asserts.

## [2.5.0] - 2026-10-12

### Added
- `RunAdapter`, the reference consumer shipped with the package: `open_run`
  (by path or identifier, refusing a producer older than 2.1.0 unless told
  otherwise), `run_geometry`, `list_batches`, `read_batch`,
  `arrival_events` with a cursor for tailing, `run_state`, `record_final`,
  and `markers`, all from the file contract; and `GapTracker`, the
  streaming form of the gap table, whose `declare!` turns every `lost` or
  `pruned` row and every closed `gap_start` / `gap_end` pair into a
  declared hole the moment the feeds announce it. On a finished run it
  declares the holes of `masks/gaps.csv` for those causes, which the suite
  asserts.
- `descriptor.toml`, written last among the post-processing products: the
  run's identity for a downstream collection — run, producer version and
  commit, configuration hash, seed, clock mode, payload geometry, the
  external record's hash and length, and the size and SHA-256 of every
  table present.
- `markers.csv` carries `PayloadRow`, the payload row of each marker's
  instant, beside `SimTime` and `Label`.
- `Sweeps` and `scripts/run_sweep.jl`: ensembles and parameter sweeps on
  the tick clock, one run per seed with overrides of any key, serial or
  over worker processes, the post-processing reduced to tables, and the
  realized totals of every run in `data/sweeps/<PREFIX>/summary.csv` with
  the sweep's provenance in `sweep.toml`.

### Changed
- The package depends on the `Distributed` standard library for the
  worker processes of a sweep.

## [2.4.0] - 2026-10-12

### Added
- `simulation.mode = "tick"`: the mission runs on a logical clock
  (`TelemetryCore.TickClock`) that advances from one component wakeup to
  the next, with the emitter and the receiver as cooperative tasks of one
  thread under a driver, so nothing is paced against the host and the
  same configuration and seed reproduce the event logs, the mask timeline,
  the batch epochs, and the metrics profile (apart from its wall-clock
  column) to the byte on one platform. The span is `mission_days`;
  `speed_up` and `mission_wall_seconds` are rejected in that mode, as is
  the console status panel, and the dashboard launcher refuses it. At an
  equal instant the emitter runs before the receiver; the receiver's idle
  and retransmission waits are cut short by the emitter's activity; a
  segment whose content interval ends at the horizon is not generated.
  `clock_anchor.toml` carries `mode` and, for a tick run, `horizon_sim` in
  place of the wall deadline. The wall mode is unchanged: its waits go
  through the same clock interface (`TelemetryCore.wait_until!`) and its
  behaviour is the one the suite and the scenario runs had before.
- `scenarios/deterministic_1d.toml`, one mission day on the tick clock,
  the smoke scenario's physics over a full day; the suite runs it twice
  and asserts the reproducibility, and asserts the production count from
  the span alone.
- `--tick` on `scripts/run_full_sim.jl` runs any configuration on the
  tick clock with its span unchanged (`TelemetryCore.tick_configuration`
  in a session: `mission_days` from the wall span, the wall keys removed,
  the status panel off). The gallery of the manual (`docs/render_assets.jl`)
  runs every scenario that way, so its figures and realized totals are
  reproducible to the byte from the scenario, the seed, and the commit
  recorded with them; the provenance file and the gallery page say so in
  place of the one-realization hedge.
- `masks/gaps.csv`, the gap table: every hole of the delivered record as a
  payload-row interval with its cause — a lost or pruned batch, a batch
  undelivered at run end, a generation gap by type (`stream`,
  `scheduled`, `recorder`), or the unreached tail of an external record —
  with the batch and the content interval, sorted by row; the rows of the
  table and the rows no delivered batch covers are the same set, which the
  suite asserts on a lossy tick run and on a run with a scheduled gap.
  Written first among the post-processing products, exported to
  `products.h5` as `masks/gaps`, computable for older runs by
  `Masks.gap_table`. The Analysis Interfaces chapter makes it the input of
  the stationary reader.

### Changed
- The manual's Analysis Interfaces chapter is organized around the two
  consumer classes a run serves. A streaming consumer follows an active run:
  attach on the sentinels and the snapshot, tail the arrival feed, keep the
  coverage, tell a pending hole from a permanent one through the
  transmission log, leave at the terminal sentinel. A stationary consumer
  opens a finished run: the delivered series on the payload grid with every
  hole declared and its cause stated (lost, pruned, generation gap by type,
  undelivered or not generated by run end, beyond the record), the arrival
  stream replayed, and the prepared products. Each class has a worked
  reader in Julia, checked against recorded runs, and describes the
  consumer archetypes a downstream analysis is built from: a run adapter
  answering five questions, a streaming engine, a detector, an online
  estimator, a replay engine, a batch inference, a gap-aware statistic.

### Fixed
- The requirement label of the delivery-delay figure keeps clear of a
  curve that ends beside its rule. The label was placed against the curves
  crossing the rule only, so a live family delivered in full shortly before
  the requirement ran up to the label's edge. The curves are now evaluated
  across the label's footprint on either side of the rule, and the label
  stands on the right of the rule when the left holds no free slot. The
  curves themselves step up at each delay rather than one delay early:
  they were drawn with the plotting library's default step, which holds
  each value up to its abscissa instead of from it.
- The suite checks the downlink during a scheduled generation gap against
  the signature of the defect fixed in 2.1.1 (no transfer placed on the
  link, at most the in-flight batches delivered) instead of against the
  rate a host reaches. A shared Windows runner delivered four batches in
  the gap where the test demanded five, without a defect in the emitter.

## [2.3.1] - 2026-10-05

### Changed
- The mission summary of a mission longer than 120 days draws the capacity
  as its mean over each mission day. Drawn pass by pass, a year of daily
  passes filled the panel as a solid block; the daily mean shows the
  seasonal extension, the missed passes, and the disruptions as levels.

- The package runs on CSV.jl 1.1 and JSON.jl 1 in place of CSV.jl 0.10 and
  JSON3, which cannot be installed together with CSV.jl 1.x. CSV.jl 1.x
  infers instants and text as types of its own and writes a `DateTime`
  without the decimal the tables have always carried, so every table is now
  read with stated column types (`TelemetryCore.read_table`) and written
  with a stated timestamp form (`TelemetryCore.write_table`). The tables
  are unchanged to the byte; in `metadata.json` the keys appear in a
  different order.

### Fixed
- Count axes that reach 10⁴ (received batches, buffer, lost batches, batch
  identifiers of the raster and of the animation) carry tick labels with one
  common power of ten in the form `10⁴`, `2×10⁴`; they read `1×10⁴` before.
- `bench/benchmarks.jl` benchmarks the event-log replay through
  `Masks.batch_states`. It still named the function at its place before
  2.0.0 and stopped there.

## [2.3.0] - 2026-10-05

### Added
- `post_processing.session_figures` switches the per-contact session
  figures off and `post_processing.session_figures_max` caps them at that
  many windows, evenly spaced over the mission (0, the default, is no cap).
  Both are read from the run's snapshot, so the publication export selects
  the same windows.
- The sentinel `RUN_POSTPROCESSING` stands beside `RUN_ACTIVE` from the stop
  of the emitter and the receiver to the end of the lifecycle: payload,
  event logs, and metrics are final while it is present.
- `scripts/postprocessing/complete_run.jl` (`Supervisor.complete_run`)
  completes a run whose supervisor process was killed during
  post-processing: the products are recomputed from the data on disk and
  the stranded `RUN_ACTIVE` is settled as `RUN_COMPLETE`, or as
  `RUN_ABORTED` when the mission itself was cut short.
- The start-up estimate prints the RAM of the figure stage (`Figure RAM`)
  and checks it against `storage.max_ram_gb`.

### Changed
- The post-processing writes the alert-latency and delivery-delay tables
  first, then the mask timeline and the raster, then the mission summary and
  the session figures. The cheap products no longer depend on the long
  stage completing.

### Fixed
- The figure stage holds one figure in memory. Every figure of a run was
  drawn inside one theme scope, which kept all of them reachable until its
  end, about 75 MiB per session figure: a 365-day mission reached 13.7 GiB
  after 163 session figures and was killed by the kernel, which left
  `RUN_ACTIVE` behind and the metrology tables unwritten. Each figure now
  has a scope of its own and is released after saving; a 360-day profile
  renders at a constant resident size.
- The suite asserts the closing of the recorder-overflow gap only when the
  overflow began before the contact opened. On a host that stalls through
  the first half second of that test the batches go straight to the link,
  its in-flight slots fill, and the gap cannot close; the assertion then
  failed on shared CI runners without a defect in the emitter.

## [2.2.0] - 2026-10-05

### Added
- `masks/batch_epochs.csv` carries a `PayloadRow` column, the payload row of
  each batch's first sample from its metadata (missing for batches written
  before 2.1.0), so point-wise mask rows re-anchor on the payload without
  reading every batch directory; the HDF5 export's `masks/batch_epochs`
  group gains the same dataset.
- The manual has a Scenario Gallery chapter: ten of the shipped scenarios
  through the figures of one run each, with the realized totals tabulated
  from the provenance record, and `scenarios/README.md` shows the mission
  summary of each. `docs/render_assets.jl` runs the scenarios, reduces the
  figures, and writes `docs/src/assets/PROVENANCE.toml` with the commit, the
  platform, and the totals of every run and the digest of every file.

### Changed
- The figures of the README and of the manual come from runs of the current
  code and live under `docs/src/assets/gallery/`. The totals quoted for the
  stress scenario and the regimes stated for the stress and the recovery
  scenario (scenario library, usage page) are those the receiver reaches
  since its slot deadlines were chained in 2.0.1: about 210 batches per
  12-hour pass, a buffer near 540 batches at the end of the stress week.

### Fixed
- The filled areas of the received-batch panels follow their staircase
  edges. The fill interpolated linearly between metrics rows while the edge
  was drawn as a step, so a low-throughput session (a recovery ramp, a
  low-latency period) showed a sloped fill crossing its own outline.
- The capacity curves of the mission summary are evaluated from the link
  model on a uniform grid, as the session figures already do, instead of
  joining the metrics rows. The rows are written on change only, so an
  interval without one — the start-up before the first pass, a contact gap
  with the recorder full — was bridged by a sloped segment the capacity
  never followed.
- The Lost strip of the mission summary shades generation gaps and
  recorder-full intervals like the panels above it, and its count
  annotation moves to the widest interval free of event edges when both
  ends of the strip carry one.
- The capacity panels draw one grid, that of the capacity axis. The buffer
  axis on the right added its own, at a spacing unrelated to the first.
- The loss marks of the mission summary and of the session figures are
  drawn without a stroke. Under a drop policy they come by the dozen per
  pass, and the stroked marks merged into a dark band that hid the loss
  color.
- The batch-routing animation keeps the newest batches inside the frame. On
  a decimated profile the sliding window trailed the leading edge of the
  queue, whose markers ran past the right-hand limit. The right margin holds
  the half of a tick label that falls on that limit, and the legend names
  the lost batches *Lost*, as the static figures do.

## [2.1.2] - 2026-10-05

### Changed
- The manual and README figures are re-rendered with the plotting code of
  2.2.0 from a new run of `scenarios/stress_8h_bursty.toml` on 2.1.1. Code and behavior are those of 2.1.1.

### Fixed
- The regimes stated for the stress and the recovery scenario (usage page,
  scenario library) follow the receiver pacing in force since 2.0.1.

## [2.1.1] - 2026-09-30

### Fixed
- The downlink keeps serving the on-board buffer during a scheduled
  generation gap. Up to 2.1.0 the emitter placed no batch on the link from
  the gap start until the first segment after the gap was due: only the
  batches already in flight (at most `telemetry.max_inflight_batches`)
  drained, so with the link up a gap left the downlink idle for most of its
  duration and delayed the backlog by about as much. The loop now wakes at
  every segment boundary while nothing is generated and refills the free
  in-flight slots. Runs with a `SCHEDULED` gap during a contact see earlier
  deliveries (`events_tx.csv` `tx`, `events_rx.csv` `ingested`) and the
  derived delivery-delay and alert-latency products; payloads, content
  epochs, and gap rows are unchanged.

## [2.1.0] - 2026-09-30

### Added
- Every batch's `metadata.json` carries `payload_row`, the payload row of
  its first sample: row `r` is the sample at
  `payload_origin + (r − 1) / sample_rate`, in external mode data row `r` of
  the input CSV.
- `config_snapshot.toml` records `payload_origin` at `[provenance]` in every
  run: the content instant of payload row 1, `start_sim_time` less
  `initial_downtime_days`, as an ISO-8601 string. External runs keep
  `external_data_rows` and `external_data_sha256` beside it.

### Changed
- For contributors: `VirtualInstrument.InstrumentState` carries the payload
  origin, `segment_samples!` became the stateless `segment_samples` with a
  row address, `segment_id`, `payload_row`, `advance_to!`, and `resumed` are
  new, and `Supervisor.record_generation_gap!` takes the resumption instant.
  A restarted emitter reuses the loaded external series instead of reading
  the file again.

### Fixed
- An external payload stays aligned with the content epoch through scheduled
  generation gaps and emitter restarts. Up to 2.0.1 the series was read
  sequentially, independently of the content clock. After a scheduled gap
  (`events_tx.csv` rows with Batch = `SCHEDULED`, in the blind spot or the
  mission phase) the content epoch jumped to the gap end while the series
  resumed where it had stopped, so every later batch carried rows from
  before its `content_epoch`: each gap added its span from the end of the
  last segment generated before it (1432 rows, 1.99 h, for a two-hour
  repointing at 0.2 Hz). A restarted emitter (`component_events.csv`: Component
  `emitter`, Event `restart`) read the series again from row 1, stamped
  with the current mission time. Runs with `physics.data_source =
  "external"` whose `[provenance.platform] package_version` is 2.0.1 or
  earlier are affected from the first `SCHEDULED` `gap_start` or the first
  emitter restart on; earlier batches and runs with neither, recorder
  overflows (`RECORDER`) included, are correct. The payload is now
  addressed by time: a segment opening at `e` starts at payload row
  `(e − payload_origin) · sample_rate + 1`.
- Segment identifiers are positions on the payload grid,
  `(e − payload_origin) / segment_duration_sec + 1`, and never repeat within
  a run. Up to 2.0.1 a restarted emitter numbered its segments from 1
  again, in either payload mode, so `seg_<id>.csv` names repeated.
- After a scheduled gap or an emitter restart, generation resumes at the
  first segment boundary of the payload grid at or after the scheduled end
  or the restart instant, and the `gap_end` row (`SCHEDULED` or `STREAM`)
  records that instant; `[gap_start, gap_end)` of a scheduled gap is exactly
  the content not recorded. Up to 2.0.1 generation resumed at the instant
  itself, which moved every later segment off the grid and, when the
  instant was off the sample grid, placed the samples between rows. In
  synthetic runs this moves post-gap content epochs by less than one
  segment period. Runs without a scheduled gap or an emitter restart are
  unchanged apart from the added fields.
- The analysis-interfaces page stated the mapping of batch `k` to rows
  `[(k − 1) · points_per_batch + 1, k · points_per_batch]` as row-exact for
  every external run; it holds only without generation gaps of any kind,
  and `payload_row` is the reference otherwise.

## [2.0.2] - 2026-10-05

### Changed
- The manual and README figures are re-rendered with the plotting code of
  2.2.0 from a new run of `scenarios/stress_8h_bursty.toml` on 2.0.1. Code and behavior are those of 2.0.1.

### Fixed
- The regimes stated for the stress and the recovery scenario (usage page,
  scenario library) follow the receiver pacing in force since 2.0.1.

## [2.0.1] - 2026-09-30

### Changed
- Documentation names the payload as what it is since 2.0.0 — a binary flag
  series — and the TOML comments call `sample_rate` the payload sampling
  frequency; the README's full tree lists `Receiver.jl`, the twelve API
  pages, the `[supervision]` section, and the complete run-directory
  contents; the Documenter build checks `Masks` and `MissionFigures` for
  missing docstrings.
- Compat bounds of the non-upgradable standard libraries are `"1"` in every
  environment: they follow the Julia version, and the former `"1.11"` bounds
  invited a bump per Julia release.
- Author metadata carries the name only (`Project.toml`, `CITATION.cff`, the
  manual).
- `.gitignore` covers the whole `data/` tree except `data/runs/.gitkeep`, a
  root `plots/` directory, and coverage outputs.
- The physics page sources the mission epoch of the shipped scenarios in
  the LISA science ground segment conventions (Baghi et al. 2026,
  arXiv:2603.22377) and lists every reference with its DOI.
- Docstrings cite the Definition Study Report with its DOI; the manual,
  the README, and the docstrings use American spelling throughout
  (backward, afterward, acknowledgment).

### Fixed
- Shaded event spans narrower than 0.6 % of the plotted range are widened
  about their center to that width: a 15-minute repointing gap on a
  seven-day mission summary had collapsed to a line, losing the band its
  legend entry shows.
- The batch-tracker animation and the showcase routing frames draw their
  markers without a stroke: with hundreds of batches in a row the default
  black strokes merged into a black bar and hid the family colors.
- The receiver paces its download slots against a running wall-clock
  deadline: a slot starts when the previous one completed, so the loop's own
  work — directory scans, the metrics row, the file moves — is absorbed into
  the slot instead of being added to every one of them. Before, the realized
  slot ran about 6 % long (a median 208.8 s between ingestions against the
  195.7 s the physical link implies), so the nominal scenario left a residual
  buffer growing by about six batches per pass on an idle host; with the fix
  the median is 194 s and the buffer clears at the end of each pass. A
  deadline still in the past after chaining means the host cannot keep the
  modeled rate, and the loop yields instead of sleeping.

## [2.0.0] - 2026-09-24

### Changed
- **Breaking:** the synthetic payload is a binary flag series — `0` on a
  segment holding noise only, `1` on a segment whose content span holds an
  event marker — instead of amplitude-calibrated LISA noise. It is declared
  by `[[events.markers]]` and involves no random draw. `seg_*.csv` keeps its
  `Amplitude` column; a physical noise or waveform model enters through
  `physics.data_source = "external"`.
- **Breaking:** `simulation.rng_seed` seeds the packet-loss channel only, and
  directly, so the loss realization of a given seed differs from 1.x.
- **Breaking:** an unknown `telemetry.bandwidth_profile` is a `[CONFIG]`
  error; it was a warning and ran as `"sine"`. `VisibilityModel` rejects an
  unknown profile at construction.
- **Breaking:** `post_processing.publication.column_width_mm` must lie in
  [100, 400]; the floor was 40.
- **Breaking:** the run identifier is
  `RUN_cfg=<8 hex>_pid=<pid>_t=<yyyymmdd_HHMMSS>`: it opens with the first
  eight hex digits of `TelemetryCore.config_sha256`, the SHA-256 of the
  configuration as sorted TOML without its provenance section, which the
  snapshot also records at `provenance.config_sha256`.
  `TelemetryCore.generate_run_id` takes the configuration.
- **Breaking:** `Emitter.pre_populate` and `Emitter.run_emitter` take the
  payload instrument as an argument — `pre_populate(instrument,
  start_sim_time, run_id; batch_size, …)` and `run_emitter(clock, link,
  run_id, instrument; batch_size, …)`. The keywords `sample_rate`,
  `segment_duration_sec`, `data_source`, `ext_path`, `initial_downtime_days`,
  and `instrument`, with their defaults, are gone; `batch_size` is required.
  The supervisor builds the instrument from `[physics]` once
  (`Supervisor.build_instrument`, anchored by `Emitter.instrument_epoch`),
  and a restarted emitter's fresh instrument in the same place.
- The batch-state timeline is read through `TelemetryCore.read_mask_timeline`
  (one task) by the raster, the point-wise expansion, and the HDF5 export;
  the supervisor counts its rows with `TelemetryCore.mask_timeline_rows`, a
  line count, instead of parsing the wide table.
- **Breaking:** `Receiver` is the ground-station loop only. The figure
  products moved to `MissionFigures` (mission summary, session figures,
  batch-state raster, the shading and legend helpers) and the batch-state
  products to `Masks` (`batch_states`, `generate_telemetry_masks`,
  `expand_pointwise_mask`); every `Receiver.<name>` of those families is
  now `MissionFigures.<name>` or `Masks.<name>`. The receiver loop no longer
  renders the mission figures at exit: `Supervisor.post_process!` renders
  them as its first stage, and a standalone `run_receiver` leaves `plots/`
  to `MissionFigures.generate_mission_plots`.
- The storage estimate sizes a PNG figure at 1.2 MB, the measured maximum of
  the standard-layout export (4800 px wide) plus a margin, instead of 2 MB.
- The test suite is split by subject into `test/<subject>.jl` files included
  from `runtests.jl`, with the shared helpers in `test/helpers.jl`; the
  publication-export testset is two testsets, the standard-layout helpers
  and the export itself.
- `Receiver.shade_outages!` is `MissionFigures.shade_spans!`, the generic span
  wash; the low-latency period's edges are dash-dot-dot, distinct from the
  dotted nominal-capacity curve; `MissionFigures.marker_times` (formerly
  `Receiver.marker_times`) reads the markers through `TelemetryCore.load_markers`.
- Every figure is composed at one standard layout — 1200 Makie units wide,
  26-unit type, 3-unit data lines, fixed panel heights — and a publication
  export scales it as a whole, so a narrower figure is a miniature of the
  standard one. Figure heights and legend rows follow from Makie's own layout
  measurements. The figures of 1.x were composed at 673 units with 12-unit
  type, and shrank type and strokes non-linearly below the design width.
- The figure legends group their entries under the headers `Link`,
  `Received`, and `Events`.
- The batch-state raster draws delivered batches in the live or the archive
  color of the other figures, according to the batch family, lists only the
  states present, and labels mission time in days.
- Mission-time axes shorter than two days carry hours instead of a single
  `Day 0` label.
- `physics.segment_duration_sec` must be a whole number of milliseconds, and
  sub-second segments now advance the content clock exactly (it advanced by
  whole seconds). A segment must hold at least one sample (was two).
- Manifests are no longer tracked. `Project.toml` with `[compat]` defines
  each environment, and every run stores the manifest it was resolved on as
  `manifest_snapshot.toml`.
- Every script includes its environment's `activate.jl` as its first
  statement; `--project` is never needed.
- `scenarios/long_segments_confusion_band.toml` is renamed
  `scenarios/long_segments_2400s.toml`.
- The storage estimate sizes a synthetic payload by
  `bytes_per_flag_sample` and an external one by `bytes_per_sample`.
- CI runs the suite on three threads, serializes documentation deployments
  across `main` and tags, and cancels superseded runs on pull requests only.

### Added
- `git_dirty` and `versioninfo` under `[provenance.platform]` of
  `config_snapshot.toml`, and `manifest_snapshot.toml` in every run
  directory.
- Storage calibration key `bytes_per_flag_sample`.
- A `[CONFIG]` warning when `post_processing.state_raster` is enabled while
  `generate_mask_timeline` is disabled: the raster is drawn from the mask
  timeline and is skipped.
- Dependabot updates for the `julia` ecosystem, weekly, grouped into one pull
  request per environment; CSV major updates are ignored until the 2.1
  migration to explicit column types.
- A "How to cite" section with a BibTeX entry in the README.
- A versioning policy: the public surface is the run-directory contract,
  the configuration schema, and the entry-point scripts (README, manual,
  CONTRIBUTING); the Julia modules and functions are the implementation
  and may change between minor releases.
- `<run_dir>/supervisor.log`: the `[SUPERVISOR]`, `[POST]`, and `[CONFIG]`
  records of the mission and its post-processing, teed with the console. A
  detached run's records reached no file.

### Removed
- **Breaking:** the noise model and its API: `lisa_noise_psd`,
  `lisa_instrument_psd`, `lisa_confusion_psd`, `welch_psd`,
  `synth_windowed_block`, `synth_windowed_block!`, `CONFUSION_FITS` and the
  other model constants of `VirtualInstrument`, `TelemetryCore.L_ARM`,
  `TelemetryCore.F_STAR`, `Metrology.payload_series`,
  `Metrology.plot_payload_spectrum`, `Supervisor.RESTART_SEED_OFFSET`, the
  `rng` keywords of the instrument and the emitter, and the
  `payload_spectrum` figure.
- **Breaking:** the keys `physics.confusion_observation_years`,
  `physics.noise_f_min_hz`, and `post_processing.payload_spectrum`. A
  configuration that carries one is rejected with the remedy named; the
  snapshot of an older run still reads.
- The narrow-width layout machinery of 1.2.0: the short label forms
  (`PlotTheme.label`), `PlotTheme.label_extent`,
  `PlotTheme.annotation_width_fraction`, `PlotTheme.legend_row_height`,
  `PlotTheme.FIG_SIZE_SUMMARY`, `PlotTheme.FIG_SIZE_SESSION`,
  `Receiver.legend_banks`, `Receiver.summary_figure_height`,
  `Receiver.LEGEND_COLGAP`, `Receiver.AXIS_MARGIN_UNITS`,
  `Receiver.LOST_STRIP_SHARE`, and `Metrology.ANNOTATION_BLOCK_TOP`.
- Dependencies `FFTW` and `AbstractFFTs`.
- The CompatHelper and TagBot workflows; the package is not registered.
- The `Pkg.add` by URL install from the README and the manual; the package
  is used from a clone of the repository, and every run is written under the
  clone's `data/runs/`.

### Fixed
- The PDF twin of the batch-state raster drew one vector rectangle per cell,
  over 10 MB for a week-long run against the 100 kB the storage estimate
  allows a vector figure. The raster is now embedded as an image.
- The link-state label of the batch-routing animation compared a percentage
  against a fraction and ignored `telemetry.min_link_factor`, so a link below
  the transfer floor read as a contact pass.
- The storage estimate's file count omitted the figure products added in
  1.2.0.
- A `retention.log_rotate_mb` giving a non-integer byte count raised an
  `InexactError` after the run directory had been created.
- The caption on the manual's landing page quoted superseded run totals.
- A batch-state raster requested without a mask timeline was skipped without
  a message.
- The alert-latency annotation read "1 live events".
- The vertical label of the delivery-delay requirement rule started above
  the corner annotation regardless of the curves and crossed the all-batches
  curve; it now takes the free end of the rule.
- On the stacked figures, a tick label at the top of the lower panel met the
  zero of the panel above across the row gap (a session y-limit of 30 or 150
  batches); the lower panel prunes the tick within 5 % of its upper limit.
- The session figure's loss count shared its row with the lost-batch pins;
  the pins sit lower.
- The lost strip's tick step was a third of the range rounded up (0, 36, 72,
  108); it is a 1–2–5 step, and the lost percentage carries three
  significant digits.
- A recorder toggling at capacity on a weak link opens a gap per transmitted
  batch, and at mission scale the boundary lines of those gaps tiled the
  panels; gaps closer than 0.5 % of the plotted range are drawn as one band.
- A zero realized alert latency drew on the axis frame; the alert-latency
  axis keeps a margin below zero.
- The pre-population progress bar wrote carriage-return frames into the log
  of a detached run; it is drawn only when the standard error stream is a
  terminal.
- The HDF5 export stamped the project `config.toml` as a run's configuration
  snapshot when the run had none, silently. The root attribute
  `config_source` says `snapshot` or `fallback`, and a missing snapshot is
  reported like a corrupt one.

## [1.2.2] - 2026-10-05

### Changed
- The manual and README figures are re-rendered with the plotting code of
  2.2.0 from the recorded run of 1.2.1. Code and behavior are those of 1.2.0.

## [1.2.1] - 2026-09-30

### Changed
- The manual and the docstrings follow the writing conventions of 2.0.1:
  literature references carry their DOIs, the LISA conventions document is
  cited in its published issue (Baghi et al. 2026, arXiv:2603.22377),
  American spelling throughout, commands without `--project=.`, and author
  metadata with the name only. Code and behavior are those of 1.2.0.
- The manual and README figures are re-rendered with the plotting code of
  2.0.1 from a new run of `scenarios/stress_8h_bursty.toml` on 1.2.1.

### Fixed
- Robson, Cornish & Liu (2019) is cited by the paper's equation numbers:
  Eq. 13 for the instrument term, Eqs. 10 and 11 for `P_OMS` and `P_acc`
  (Eq. 1 before).

## [1.2.0] - 2026-09-13

### Added
- An `activate.jl` in every environment — the package, `test/`, `docs/`,
  `bench/`, `scripts/` — so `julia -i test/activate.jl` opens a REPL in that
  environment.
- Two run products behind their own `[post_processing]` flags, both in the
  publication export: `state_raster.png`, the batch-state timeline as a
  raster (one column per batch, one row per recorded event, the LIFO
  backfill visible as the higher identifiers turning first), and
  `payload_spectrum.png`, the delivered payload's spectrum against the
  analytic model it was drawn from.
- The README and the manual's landing page show the mission summary and the
  batch-routing animation of `scenarios/stress_8h_bursty.toml`;
  `PROVENANCE.toml` beside them records the run and the commit, and
  `generate_gif.jl --web` renders the animation at that size.
- An abstract in `CITATION.cff`.

### Changed
- The mission summary draws the low-latency periods and the event markers
  of a run, which were simulated but never plotted; the session figures
  carry the markers too.
- Every frame of the batch-routing animation states the mission clock, the
  link state, and the onboard and ground counts, in the live and archive
  hues of the static figures.

### Fixed
- Publication exports below about 100 mm were unusable: legend rows
  crowded the panels and labels overlapped. Short label forms and a
  label-aware height keep them legible; the design width renders as before.
- In-axis annotations move to the end of the axis the event rules leave
  free, and the delivery-delay requirement rule stops above its annotation
  block.
- The Lost strip of the mission summary rendered a lossless run as an empty
  panel; it carries integer ticks, a zero line clear of the frame, and
  states its count.
- The animation's frame budget rendered runs between one and two times its
  ceiling in full.
- The storage estimate counts the two new figure products.
- The mask expander reads the timeline on one task, which avoids a logged
  CSV.jl failure on the wide rows.

## [1.1.1] - 2026-09-30

### Changed
- The manual and the docstrings follow the writing conventions of 2.0.1:
  literature references carry their DOIs, the LISA conventions document is
  cited in its published issue (Baghi et al. 2026, arXiv:2603.22377),
  American spelling throughout, commands without `--project=.`, and author
  metadata with the name only. Code and behavior are those of 1.1.0.

### Fixed
- Robson, Cornish & Liu (2019) is cited by the paper's equation numbers:
  Eq. 13 for the instrument term, Eqs. 10 and 11 for `P_OMS` and `P_acc`
  (Eq. 1 before).

## [1.1.0] - 2026-09-11

### Added
- The manual on GitHub Pages (`stable` from the version tags, `dev` from
  `main`), and CI legs on macOS and Windows beside Linux.
- `dashboard.receiver_status_panel` (default `false`): the receiver's
  terminal status panel is opt-in.
- Specific exceptions at the public interfaces: `[CONFIG]` errors from
  `load_config`, `ArgumentError` for missing run inputs, and
  `TelemetryCore.StorageBudgetError` from the storage gate.
- Issue forms, a pull-request template, and `codecov.yml`.

### Changed
- Figures: the counterfactual FIFO drain is dotted reddish purple instead
  of the onboard-buffer signature; legends list only the series drawn and
  carry the edge style of the in-axis shading; the lost-batch strip is
  labeled "Lost batches".
- `Supervisor.mission_plan` leaves its argument unchanged; supervisor
  notices are `[SUPERVISOR]` logger records.
- The keyword `segment_duration_sec` replaces `seg_dur` in the emitter entry
  points and the instrument.
- Documentation: the clone URL is HTTPS; American spelling throughout.

### Fixed
- The post-processing wrappers exited silently on a missing run directory or
  malformed arguments; they report the cause and exit with status 1.
- A malformed `start_sim_time` in a run snapshot is reported instead of
  silently re-anchoring the time axis.

## [1.0.0] - 2026-09-10 and [0.9.0] - 2026-08-07

The releases before the repository went public, folded into one paragraph:
the end-to-end emitter–receiver simulation over a simulated deep-space link
with live-FIFO and archive-LIFO routing; Bernoulli and Gilbert–Elliott loss,
the disruption timeline, and the round-trip light time in the retransmission
loop; the contact schedule, event markers, scheduled generation gaps, and
the on-board recorder ceiling; the physical link-rate parameterization;
storage governance with a pre-run gate; supervised component tasks with
re-attachment after a failure; the alert-latency and delivery-delay
metrics; the filesystem analysis contract, the HDF5 and publication
exports, and run provenance (package version, git commit, platform); the
scenario library; `CITATION.cff` and `CONTRIBUTING.md`; static QA (Aqua,
ExplicitImports, JET) in the test suite. The package, module, and
repository were renamed to DeepSpaceTelemetry on 2026-08-02.

[3.1.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v3.0.1...v3.1.0
[3.0.1]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.11.0...v3.0.0
[2.11.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.10.0...v2.11.0
[2.10.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.9.0...v2.10.0
[2.9.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.8.0...v2.9.0
[2.8.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.7.0...v2.8.0
[2.7.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.6.2...v2.7.0
[2.6.2]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.6.1...v2.6.2
[2.6.1]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.6.0...v2.6.1
[2.6.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.5.0...v2.6.0
[2.5.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.4.0...v2.5.0
[2.4.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.3.1...v2.4.0
[2.3.1]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.2.0...v2.3.0
[2.2.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.1.1...v2.2.0
[2.1.2]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.1.1...v2.1.2
[2.1.1]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.0.1...v2.1.0
[2.0.2]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v1.2.0...v2.0.0
[1.2.2]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v1.1.0...v1.2.0
[1.1.1]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v0.9.0...v1.0.0
[0.9.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/releases/tag/v0.9.0
