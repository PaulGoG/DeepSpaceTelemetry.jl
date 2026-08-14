# Changelog

Notable changes to DeepSpaceTelemetry. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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

### Changed
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
