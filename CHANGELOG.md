# Changelog

Notable changes to DeepSpaceTelemetry. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Event markers (`[[events.markers]]`): declared instants of interest,
  stamped into `metadata.json` (`markers`) and `events_tx.csv` (`marker`
  rows) by the emitter when the holding batch is finalized, recorded in
  `markers.csv` at mission start, and evaluated by the alert-latency
  metric (`Metrology.marker_latency_table`, `alert_latency_markers.csv`,
  marker curves on the figure). A marker may trigger a low-latency period
  after a reaction delay. `[ground] processing_latency_hours` (default 1 h)
  is reported on top of every alert latency. The shipped scenario's
  low-latency period is now marker-triggered.
- Contact schedule (`[contacts]`): seasonal extension of the daily window
  (cosine-modulated over `season_period_days`, peaking at
  `season_peak_day_of_year`), per-date exceptions (missed or shortened
  passes), explicit pass lists (`[[contacts.passes]]` or `schedule_csv`),
  and low-latency periods (`[[contacts.low_latency_periods]]` at a
  constant capacity fraction, `low_latency_enabled` switch). One session
  figure per contact window (`session_day<kk>_low_latency_detail.png` for
  periods); the delivery-delay table flags deliveries inside a period
  (`LowLatency` column, `via_low_latency` count); the mission banner
  summarizes the schedule. The shipped scenario gains a 3-hour
  half-capacity period on the evening of day 4.
- Physical link-rate parameterization: `telemetry.downlink_kbps` with
  `telemetry.onboard_data_rate_kbps` (mutually exclusive with
  `max_batches_per_hour`) define the batch transfer time through the batch
  content span; `telemetry_settings` reports `nominal_batch_transfer_sec`
  and the catch-up ratio, printed in the mission banner; `run_receiver`
  takes `batch_transfer_sec` instead of `max_batches_per_hour`.
- Delivery-delay metric: measurement-to-ground delay of every generated
  batch, the fraction within `post_processing.delivery_requirement_hours`
  (default 24 h, the LISA requirement; undelivered batches are
  non-compliant), median and 95th percentile, in `delivery_delay.csv` and
  `plots/delivery_delay.png` (`post_processing.delivery_delay`, on by
  default).
- Round-trip light time in the retransmission loop
  (`telemetry.range_million_km`, default `0` = immediate retry; the shipped
  scenarios use 50 × 10⁶ km ≈ 333 s): a lost transfer is re-served no
  earlier than one round trip after the loss was detected while the other
  in-flight batches keep being served, and the link idles only when every
  in-flight batch awaits its round trip. `telemetry_settings` exposes the
  derived `round_trip_light_time_sec`; `run_receiver` takes it as a
  keyword.
- Component warm-up before the mission clock starts
  (`Supervisor.warm_up_components!`): both loops are compiled against a
  scratch directory so that first-call compilation — seconds of wall clock,
  hours of mission time at high `speed_up` — no longer elapses after the
  clock anchor.
- `Metrology` module with the alert-latency metric: for every live batch
  delivered, the ground availability of the data at look-back `δ` after the
  event, under the realized doctrine and under a counterfactual FIFO drain
  that re-assigns the same service completions in content order; median and
  interquartile curves in `alert_latency.csv` and `plots/alert_latency.png`
  (`post_processing.alert_latency`, `alert_lookback_hours`). Runs by default
  after the mask timeline.
- `Supervisor` module: `run_mission` is the headless pipeline as a library
  call (validation, storage gate, models and provenance in a `MissionPlan`,
  the run directory and lifecycle sentinels on every exit path, supervised
  components, post-processing); `supervise!` runs any set of component
  spawners under the abort/continue/restart policies with the heartbeat
  watchdog, and `CleanFileLogger` is the component log sink (pure `Logging`,
  no `LoggingExtras`). `scripts/run_full_sim.jl` is argument parsing plus
  one call; the point-wise mask expansion lives in the package as
  `Receiver.expand_pointwise_mask`, and `apply_telemetry_mask.jl` is its
  command-line wrapper. Accessors `physics_settings` and
  `supervision_settings` complete the configuration layer. New stdlib
  dependencies `Logging` and `SHA`; the script environment drops
  `LoggingExtras`, `TerminalLoggers`, `SHA`, `TOML`, `Random`, `Logging`.
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

### Deprecated
- Configuration keys `simulation.test_duration_sec` (now
  `simulation.mission_wall_seconds`) and
  `post_processing.generate_batch_matrix` (now
  `post_processing.generate_mask_timeline`), and the `[disaster]` section
  name: accepted with a one-time warning until 1.0.0.

### Removed
- The count-delta heuristic batch-state replay for runs without event logs
  (`reconstruct_batch_states` now names the exact replay, formerly
  `reconstruct_batch_states_exact`; `batch_states(run_dir, df)` drops the
  visibility-model argument and errors on a run without `events_tx.csv`).
- Submodule `export` lists: every public name is addressed qualified
  (`TelemetryCore.x`, `ChannelEffects.x`, `PlotTheme.x`, ...), as the code
  base already did.
- The `DrWatson` dependency: its only use was `savename` in
  `generate_run_id`, whose `RUN_pid=<pid>_t=<stamp>` layout is now produced
  directly; `safesave`-style backup rotation and snapshot provenance were
  already implemented in `TelemetryCore`.
- The `.ack` marker files in `link/`: the receiver created them and the
  emitter only deleted them, while in-flight occupancy has always been the
  `link/` directory listing. Consumers never depended on them (`link/` is
  off-limits by contract).

### Removed
- `DataSegment.is_signal` and the instrument's per-segment signal flag:
  event instants are markers, not random draws. The synthetic noise
  realization of a given seed changes (one fewer RNG draw per segment).

### Deprecated
- `physics.signal_injection_probability` is accepted with a warning and
  ignored (removed at 1.0.0).

### Changed
- The API reference is split into one manual page per module
  (`docs/src/api/`), keeping every generated page under Documenter's size
  threshold.
- `Receiver.plot_session` takes a `ContactWindow` and a file stem instead of
  a day index (`Receiver.session_figure_stems` enumerates them);
  `PlotContext` no longer carries the session window fields.
- `mission_profile.csv` column `Ground_Archive` (the live + archive total)
  is `Ground_Total`, matching the renamed `MissionMetrics.ground_total`
  field; readers normalize legacy files through `normalize_profile!`.
- `BatchStates` fields are spelled out (`onboard_live`, `onboard_archive`,
  `link_live`, `link_archive`, `ground_live`, `ground_archive`, `lost`).
- Mask state 2 is named "Link" everywhere (manual, terminal viewer,
  animation); `generate_telemetry_gif` and `expand_pointwise_mask` replace
  `create_telemetry_gif` and `apply_mask`/`expand_mask`.
- The batch-routing animation adopts the Okabe–Ito palette of the static
  figures — color encodes the stage (onboard orange, link blue, ground sky
  blue / green), marker shape the family (circle live, diamond archive) —
  and derives its marker size from the theme constant.
- `generate_mission_plots` is decomposed into a `PlotContext` built once per
  run and named components (`plot_mission_summary`, `plot_session`, the
  shading and legend helpers); the rendered figures are pixel-identical.
- Configuration accessors `telemetry_settings`, `visibility_model`,
  `loss_channel_settings`, and `disruption_event_settings` single-source the
  types, defaults, and bounds of `[telemetry]`, `[packet_loss]`, and
  `[[disruption.events]]`; the validator, the channel builders, the storage
  estimator, the post-processing tools, and the entry point all read through
  them (the builders no longer repeat the range checks). Consequently
  `build_loss_model` and `loss_retry_limit` reject a malformed section even
  when the channel is disabled, as the validator always did.
- `run_emitter` keyword `initial_segments` is `pending_segments` (the partial
  batch carried across `pre_populate` and the loop now has one name); the
  test-only `test_duration_sec` keyword of `run_emitter`/`run_receiver` is
  removed — callers pass `deadline`, as production always did.
- The dashboard launcher spawns a pure-Julia log follower
  (`scripts/follow_log.jl`) instead of `tail -F`, uses absolute paths, and
  no longer changes the working directory.
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
- A 24-hour contact window (`telemetry.session_duration_hours = 24`, the
  validator's upper bound) was never visible: `Time` arithmetic wrapped the
  window end onto its start. A full-day session is now always visible.
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
