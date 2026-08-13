# Changelog

Notable changes to DeepSpaceTelemetry. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
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
