# Changelog

Notable changes to DeepSpaceTelemetry. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `metadata.json` carries `content_epoch` (first-sample mission timestamp)
  beside `created_at` (finalization instant); `masks/batch_epochs.csv` gains a
  `ContentEpoch` column. New helpers `read_batch_metadata` and
  `batch_content_epochs`.
- Emitter content-lag telemetry: a persistent lag above one segment period
  (longer than `EMITTER_LAG_WARN_SEC`) warns once that the host cannot keep
  pace; the maximum lag is logged at loop exit. Pacing sleeps are capped at
  `EMITTER_MAX_SLEEP_SEC` so heartbeats and stop signals stay responsive at
  low `speed_up`.
- Single-thread advisory (`thread_advisory`) printed by the headless entry
  point; README and manual document the recommended `--threads=3`.
- `[storage] max_ram_gb`: the pre-run gate now estimates the post-processing
  replay RAM (new `replay_ram_bytes` field and `bytes_replay_cell`
  calibration key) and refuses configurations exceeding the budget.
- `RetentionPolicy`: the retention custodian's parameters are a typed
  immutable struct (grace window held as a `Millisecond` period); the
  pruning queue is materialized lazily on watermark breach, bounding its
  growth on missions that never reach the watermark.
- Receiver re-attach synthesizes `ingested` records for batches present in
  `ground/` without a delivery record (crash-window reconciliation; formerly
  warning-only).
- Platform provenance: every `config_snapshot.toml` now carries
  `[provenance.platform]` — hostname, OS, CPU model and core count, memory,
  Julia version, thread and BLAS-thread counts.

### Removed
- The `DrWatson` dependency: its only use was `savename` in
  `generate_run_id`, whose `RUN_pid=<pid>_t=<stamp>` layout is now produced
  directly; `safesave`-style backup rotation and snapshot provenance were
  already implemented in `TelemetryCore`.
- The `.ack` marker files in `link/`: the receiver created them and the
  emitter only deleted them, while in-flight occupancy has always been the
  `link/` directory listing. Consumers never depended on them (`link/` is
  off-limits by contract).

### Changed
- `BernoulliLoss`, `GilbertElliottLoss`, and `InstrumentState` carry their
  RNG as a type parameter (`{R<:AbstractRNG}`) instead of an abstract field,
  so the per-attempt and per-segment draws dispatch statically;
  `BernoulliLoss` is immutable.
- Batch directory names are a single wire format: `batch_name`, `batch_id`,
  `is_live_batch`, `is_archive_batch`, and `is_batch_name` replace the
  parsing idioms scattered over the emitter, the receiver, the replay, and
  the terminal viewer. `runs_root` and `latest_run_id` single-source the
  run-directory discovery of the scripts; `cleanup.jl` and
  `apply_telemetry_mask.jl` resolve paths through `run_directory` (they
  honour a redirected `DATA_ROOT`), and the latter loads the package instead
  of including a second copy of `TelemetryCore`.
- Pre-populated batches stamp `created_at` and their `gen` event at the
  finalization instant (end of the last segment's content), consistently
  with mission-phase batches; the content epoch is recorded separately.
- Exact batch-state replay rewritten around a batch-ID position map: event
  application is O(1) (formerly quadratic `filter!` scans) and per-batch
  causal order (`gen` → `tx` → terminal) is enforced, so cross-component
  timestamp skew can no longer regress a batch's mask state.
- Strain synthesis caches its inverse-FFT plan and reuses draw/output
  buffers; seeded streams are unchanged.
- Configuration rejections throw `ArgumentError` uniformly (via
  `config_error`); a malformed `[packet_loss]` section is rejected even
  while disabled; `[dashboard]` and `[post_processing]` values are
  type-checked at validation time; the loss-saturation warning composes the
  worst-channel-state loss with the largest disruption `loss_multiplier`.
- Storage estimator counts the vector-PDF twin of every figure (bytes and
  file count) and uses named constants for its margins and slacks.

### Fixed
- Emitter pacing was anchored to the loop's own start and rounded the
  segment period to whole milliseconds: the data stream started several
  mission hours late (never recovered) and ran about 2 % slow at the shipped
  configuration, ending 7–8 mission hours before the declared mission end.
  Generation now follows the mission clock — a segment is produced once its
  content interval has elapsed, due times are computed from the clock anchor,
  a late start or a stall is recovered by catch-up — so the content epoch of
  the stream tracks mission time within one segment period.
- Transmission opportunities were coupled to the generation cadence (one
  batch per segment period); every free in-flight slot is now refilled on
  each iteration, so the downlink rate is bounded by the in-flight cap and
  the receiver's service rate alone.
- Emitter heartbeat removal is exception-safe (`try`/`finally`, matching the
  receiver); the mask timeline sizes by the true maximum batch ID so holes
  in the ID space no longer fault post-processing; the storage estimator
  compares loss-model names case-insensitively.
- `generate_gif.jl` failed with an `UndefVarError` after the explicit-import
  migration: `with_theme` is now taken from `CairoMakie` rather than through
  `PlotTheme`.
- Corrected identifiers and labels that contradicted their semantics: the
  dashboard "Ground Archive" line (the counter is the live + archive total),
  a 1-based mask-expansion index named `_zero_based`, and "packet" wording in
  the live viewer for what are batches.
- Documentation currency: README project tree (docs environment files,
  repository dotfiles, full run-directory contract) and the figure-export
  description (vector PDF alongside raster PNG).

### Changed
- Renamed (2026-08-02, recorded here for consumers): the package, module, and
  repository **SpaceTelemetrySim → DeepSpaceTelemetry** — a breaking change
  for any code `using` the old module name.

## [0.9.0] - 2026-08-07

### Added
- End-to-end telemetry simulation: satellite emitter and ground-station
  receiver exchanging batch directories over a simulated deep-space link,
  with live-FIFO priority and archive-LIFO backfill routing.
- Physics payload: amplitude-calibrated synthetic LISA strain (windowed
  overlap-add FFT synthesis against the analytic one-sided PSD) and gapless
  external CSV ingestion with startup coverage reporting and SHA-256 input
  provenance.
- Channel models: Bernoulli and two-state Gilbert–Elliott packet loss with
  retransmission and retry budgets; scheduled disruption events with
  blackout, linear recovery ramp, and elevated loss.
- Storage governance: startup per-artifact-class estimation with
  mitigation-aware budget gating, and an opt-in retention custodian pruning
  delivered payloads under a grace-window guarantee.
- Process-flow resilience: supervised component tasks with
  abort/continue/restart policies, heartbeat watchdog, persisted mission
  clock anchor, component re-attachment contracts, generation-gap events,
  and lifecycle sentinels (`RUN_ACTIVE`/`RUN_COMPLETE`/`RUN_ABORTED`, `HALT`).
- Data products: ground-truth event logs with exact batch-state replay, the
  2D mask timeline, point-wise 0/1 expansions (plus a dependency-light
  standalone expander), batch generation-epoch map, mission and session
  figures (vector PDF + raster PNG), and a batch-routing animation.
- Filesystem analysis interface for external pipelines (documented contract:
  read/copy-only consumers, atomic delivery, availability windows).
- Static QA shipped with the tests: Aqua, ExplicitImports, and JET alongside
  unit, physics-validation, and three end-to-end integration suites.

[Unreleased]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/releases/tag/v0.9.0
