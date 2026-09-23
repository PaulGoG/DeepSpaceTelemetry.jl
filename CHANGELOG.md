# Changelog

Notable changes to DeepSpaceTelemetry. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

## [1.2.0] - 2026-09-13

### Added
- An `activate.jl` for every environment — the package, `test/`, `docs/`,
  `bench/`, `scripts/` — activating and instantiating it without output, so
  `julia -i test/activate.jl` opens a REPL in that environment. The entry
  points already did this on start-up; these files serve interactive work.
- Two figures from the shipped `scenarios/stress_8h_bursty.toml` under
  `docs/src/assets/`, shown in the README and on the manual's landing page:
  the mission summary of a week carrying an 18 h solar-flare blackout, its
  recovery ramp, a partial ground-station outage, and a scheduled generation
  gap; and the batch-routing animation of the same run. `PROVENANCE.toml`
  beside them records the run, the commit, the realized totals, and the
  transform that produced each file from the run's own export.
- An abstract in `CITATION.cff`, stating what the framework simulates, what
  is mission-agnostic in it, and how an analysis pipeline couples to a run.
- A `--web` rendering profile for `scripts/postprocessing/generate_gif.jl`,
  writing the size the README and the manual carry (900 px, at most 240
  frames) as `telemetry_animation_web.gif`, so the published animation
  follows from one command instead of an external decimation pass.
- `Receiver.low_latency_spans`, `Receiver.marker_times`,
  `Receiver.shade_low_latency!`, and `Receiver.mark_events!`; `PlotContext`
  carries the low-latency and event-marker spans of a run.
- Two figures every run now produces, each behind its own
  `[post_processing]` flag (`state_raster`, `payload_spectrum`, both default
  `true`) and included in the publication export. `state_raster.png` draws the
  batch-state timeline as a raster — one column per batch, one row per
  recorded event, one color per state — in which generation is the diagonal
  boundary, each pass turns a block of columns to the ground color, and within
  a block the higher identifiers turn first, which is the LIFO backfill made
  visible. `payload_spectrum.png` estimates the spectrum of the delivered
  payload against the analytic `S(f)` the synthesis drew it from, with the
  instrument term separated and the first bin the synthesis block resolves
  marked; external payloads are skipped, having no model to compare against.
- `VirtualInstrument.welch_psd` (one-sided Welch estimate, Hann windows at
  half overlap, normalized to integrate to the variance),
  `Metrology.payload_series` (the longest stretch of consecutively numbered
  delivered batches, since splicing across a LIFO gap would put a
  discontinuity into a spectrum), `Metrology.plot_payload_spectrum`,
  `Receiver.plot_state_raster`, `Receiver.raster_figure`, and
  `PlotTheme.COLOR_FUTURE`.
- `PlotTheme.label_extent`, `PlotTheme.legend_row_height`,
  `PlotTheme.annotation_side`, `PlotTheme.annotation_width_fraction`,
  `Receiver.figure_legend_entries`, `Receiver.summary_figure_height`,
  `Receiver.upright_rules`, `Receiver.LOST_STRIP_SHARE`,
  `Receiver.AXIS_MARGIN_UNITS`, `Metrology.ANNOTATION_BLOCK_TOP`, and
  `Metrology.ANNOTATION_BLOCK_LEFT` — the narrow-width layout machinery.

### Changed
- The README carries one documentation badge, pointing at the manual of the
  latest release; the build of `main` stays deployed and is reached through
  the version selector.
- The mission summary draws the low-latency periods of a run and the instants
  of its declared event markers, which were simulated and recorded but never
  plotted: a marker-triggered period had appeared in the capacity curve as an
  unexplained half-height pass. The periods are washed in the capacity color
  under the curve they explain, the markers drawn as solid rules — the one
  vertical style no shaded window uses for its edges — and the session
  figures carry the markers as well.
- Every frame of the batch-routing animation states the mission clock, the
  link state, and the onboard and ground counts. Frames are metrics rows,
  whose cadence is change-driven, so the animation previously carried no
  mission time at all. Its color now encodes the routing family in the live
  and archive hues of the static figures, the marker shape repeating the
  distinction: the row already carries the stage, and in a row of hundreds of
  batches the marker shapes merge.
- The manual shows the batch-routing animation on the physics page, beside
  the routing doctrine it demonstrates; the file was deployed with the site
  but referenced by no page.
- `docs/src/assets/PROVENANCE.toml` records the platform of the run behind
  the README figures and states that the realized counts depend on how much
  mission time the host completes inside the wall-clock budget.

### Fixed
- Publication exports below about 100 mm were unusable. A single-column
  figure gave its legend two columns and eight rows, which left the panels so
  short that the rotated y-labels of the Lost strip and the panel above it
  overlapped, and the low-latency note of a session figure ran past the axis.
  Legend entries, the Lost strip's label, and the in-axis counts now take
  short forms below the narrow-figure threshold — the same mechanism the axis
  labels already used — which holds the legend to four rows at 86 mm; and the
  figure gains height whenever two adjacent panels' labels would still meet
  (`Receiver.summary_figure_height`). The design width renders exactly as
  before.
- In-axis annotations moved to whichever end of the axis the disruption
  rules, generation gaps, low-latency periods, and event markers leave free
  (`PlotTheme.annotation_side`), and the delivery-delay requirement rule stops
  above its annotation block instead of passing behind it — a requirement
  beyond every realized delay sits at 87 % of the axis, inside the block.
- The Lost strip of the mission summary rendered a lossless run as an empty
  panel: the flat zero stair coincided with the axis frame, the automatic
  ticks fell on fractional batch counts, and the count annotation was gated
  on a non-zero count, so nothing distinguished "no batch was lost" from a
  panel that had failed to render. The strip carries integer ticks, a zero
  line clear of the frame, and states its count in either direction.
- The animation's frame budget divided the metrics length by the ceiling
  with `floor`, so any run between one and two times that ceiling rendered in
  full — the seven-day stress scenario wrote 1291 frames against a declared
  maximum of 800. The budget rounds up.
- The storage estimate counts the two new figure products, so the gate that
  refuses a run whose footprint exceeds the `[storage]` budget sizes the
  plots directory correctly rather than two figures short.
- Expanding a mask row reads the timeline with `ntasks = 1`: one wide row per
  event defeats CSV.jl's multithreaded chunking, which logged a failure
  before falling back to a single task anyway. The dependency-light copy of
  the expander shipped for collaborators does the same.
- The emitter-pacing testset asserted a production count that presumes the
  host keeps pace with the accelerated clock — one 60 s segment synthesized
  and written every 100 ms at `speed_up = 600` — which a cold or loaded CI
  runner misses. The epoch arithmetic and the causality bounds are asserted
  unconditionally; the end-of-span coverage and the steady-state lag are
  asserted only when the run kept pace, and a warning names the shortfall
  otherwise. The scenario testset asserted a delivered-batch count from the
  12-second smoke run for the same reason; its floor now separates a pipeline
  that moved data from one that stalled, and the per-segment cost that sets
  the rate stays a benchmark.

## [1.1.0] - 2026-09-11

### Added
- The manual is published on GitHub Pages
  (`https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/`, `dev` for the
  `main` branch); the CI docs job deploys it on every push to `main` and on
  every version tag, the build declares its canonical URL, and the README
  carries the docs badges.
- CI test legs on macOS and Windows for the current Julia release, and
  explicit `permissions:` blocks on the workflow. Legs on a Julia version
  other than the one the manifests were resolved on discard them and resolve
  their own environment, because standard-library membership moves between
  versions (`Zstd_jll` is a standard library on 1.13 and a registered package
  on 1.12); those legs verify the `julia` compat bound, and the blocking
  Linux leg on the current release verifies the manifests as committed.
- `dashboard.receiver_status_panel` (default `false`): the receiver's
  console status panel, a text panel that clears the terminal on every
  receiver iteration, is opt-in. `TelemetryCore.dashboard_settings` returns
  the validated `[dashboard]` flags; `Receiver.run_receiver` takes the
  keyword `status_panel`; `scripts/launch_dashboard.jl` reads the accessor.
- `TelemetryCore.StorageBudgetError`, thrown by the storage gate in place of
  a generic error.
- Named constants for values that were inline literals:
  `TelemetryCore.HEARTBEAT_INTERVAL_MS`, `MS_PER_HOUR`, `MS_PER_DAY`,
  `EMITTER_PERIOD_WARN_MS`, `RECEIVER_SLOT_WARN_MS`;
  `Supervisor.RESTART_SEED_OFFSET`; the six coefficients of the
  Robson–Cornish–Liu instrument PSD in `VirtualInstrument`;
  `Metrology.QUARTILE_BAND_ALPHA`; `PlotTheme.COLOR_COUNTERFACTUAL`,
  `COLOR_OUTAGE`, `COLOR_MARKER`, `COLOR_GUIDE`.
- `PlotTheme.line_advance` (line height of the annotation face at a print
  style) and `Receiver.shading_patch` (legend entry carrying the edge style
  of an in-axis shading).
- Docstrings on `PROJECT_ROOT`, `hours_period`, `PROFILE_MEAN_SUBINTERVALS`,
  `render_log_value`, `print_banner`, `LEGEND_COLGAP`; field lists on
  `SimulationClock`, `DataBatch`, `DataSegment`; keyword-argument lists on
  `Emitter.pre_populate` and `Emitter.run_emitter`.
- Tests: the caller's configuration is unchanged by `mission_plan`; the
  dashboard accessor and its validation; the specific exception types.
- Repository files for the public release: issue forms and a pull-request
  template under `.github/`, `codecov.yml` (thresholds, excluded paths), and
  `.gitattributes` normalizing line endings for the Windows CI checkout.

### Changed
- Figures: the counterfactual FIFO drain is drawn dotted in reddish purple
  instead of the onboard-buffer signature (orange, dashed); interquartile
  bands carry boundary lines; the delivery-delay legend lists only the
  series drawn; the disruption, outage, and gap legend patches carry the
  edge style of the in-axis shading; every color comes from `PlotTheme`;
  axis labels with the look-back symbol are LaTeX strings; the theme's
  figure padding is the single source of the value; the data-line floor at
  reduced widths is 0.9 units (≈ 1 pt at 86 mm); edge and reference strokes
  scale with the print style; the lost-batch strip is labeled "Lost
  batches"; the delivery-delay requirement label no longer meets the
  annotation block.
- Animation: legend and axis typography derive from one `PlotStyle` for the
  1400-unit canvas, and the raster density is declared explicitly.
- `Supervisor.mission_plan` no longer mutates its argument; the stamped copy
  travels in `MissionPlan.cfg`. Component failure, restart, policy-continue,
  abort, and watchdog notices are logger records tagged `[SUPERVISOR]`;
  `supervise!` drops its `orig_stdout` keyword; stage messages in sentence
  case.
- Specific exceptions at the public interfaces: `[CONFIG]` errors from
  `load_config`, `ArgumentError` for missing run inputs (`load_clock_anchor`,
  the run-ID reuse guard, the post-processing readers), `StorageBudgetError`
  from the storage gate; the replay-RAM message names
  `generate_mask_timeline`.
- `estimate_artifacts` requires `physics.batch_size`; `save_clock_anchor`
  rotates an existing anchor; `validate_config` and the link model read
  `start_sim_time` through the checked coercion; the grace-window check reads
  the segment duration through the physics accessor.
- Keyword `segment_duration_sec` replaces `seg_dur` in `Emitter.pre_populate`,
  `Emitter.run_emitter`, and the `InstrumentState` field.
- Configuration files: one canonical invocation line in every header, and
  scenario headers that name settings only.
- Test suite: every approximate comparison states its tolerance; the test
  environment drops `Random`.
- Documentation: component status follows the entry points and lists the
  scripts; "DSN" is defined once as the generic ground-network term; the
  clone URL is HTTPS and `Pkg.add` by URL names the release tag;
  CONTRIBUTING states the formatter installation and the CI matrix; the
  usage page documents the status panel; American spelling throughout; the
  physics page no longer names a downstream project; the repository-rename
  entry sits under 0.9.0.
- Register and comment currency across the sources: plan references,
  former-implementation narratives, and colloquial phrasing removed.

### Fixed
- The CLI wrappers `apply_telemetry_mask.jl`, `standalone_mask_expander.jl`,
  `export_hdf5.jl`, `export_publication_figures.jl`, and `generate_gif.jl`
  exited silently on a missing run directory or malformed arguments: their
  messages had been reduced to discarded string literals in 1.0.0. They
  report through `@error` and exit with status 1.
- The manifests of the test, docs, bench, and scripts environments recorded
  the package at version 0.9.0.
- `Receiver`: a malformed `start_sim_time` in the run snapshot is reported
  instead of silently re-anchoring the time axis.

## [1.0.0] - 2026-09-10

### Added
- A plain reference list closing the physics page (Definition Study Report,
  Rosetta Stone, Gilbert 1960, Elliott 1963, Kleinrock 1975,
  Robson–Cornish–Liu 2019); the in-text mentions point at it by author and
  year, without a citation dependency.
- Doctests: `jldoctest` examples on the pure accessors (`batch_name`,
  `batch_id`, `is_live_batch`, `VisibilityModel`, `get_bandwidth_factor`,
  `normalize_target_rows`, `telemetry_settings` in both capacity forms,
  `mission_wall_seconds`, `stationary_loss_rate`,
  `disruption_loss_multiplier`), executed by the docs build.
- Profile-mean guardrail: `TelemetryCore.profile_mean` (quadrature mean of
  the pass profile) and `TelemetryCore.capacity_balance` (capacity of one
  nominal pass against the daily production); `validate_config` warns when
  the physical rate pair meets a shaped `bandwidth_profile`, stating the mean
  and the balance, and the mission banner prints a `Capacity:` line.
- `CITATION.cff` (Citation File Format 1.2.0), `CONTRIBUTING.md` (working
  conventions), a monthly dependabot schedule for GitHub Actions, and the
  CompatHelper workflow (weekly, covering the package and its four auxiliary
  environments).
- Tag-triggered CI runs and the TagBot workflow (active once the package is
  registered); the docs build declares doctests explicitly and records that
  deployment is deferred until the repository is public.
- Scenario library under `scenarios/`: eleven complete configurations with a
  coverage matrix and the expected regime of each (`scenarios/README.md`),
  every file validated by the suite and the smoke scenario run end to end
  in it. `config.toml` is now a copy of the reference scenario
  `recovery_12h_seasonal.toml` (physical link rates, flat profile, 12 h
  seasonal-peak passes, bursty loss, three disruptions, one marker); the
  previous default is preserved as `abstraction_gaussian_peak.toml` and the
  presentation scenario as `backlog_recovery_sine.toml`.
- Publication figure export (`Publication.export_publication_figures`,
  `[post_processing.publication]`, `scripts/postprocessing/export_publication_figures.jl`):
  every figure re-rendered at a declared printed width in PDF or SVG with
  a `PROVENANCE.toml` sidecar; `PlotTheme.PlotStyle` scales figure
  geometry, strokes, and fonts (floored at 7 pt) for the width, and
  legends wrap by available width.
- HDF5 product export (`Export.export_hdf5`, `post_processing.hdf5_export`,
  `scripts/postprocessing/export_hdf5.jl`): event logs, metrics profile,
  batch-state timeline, batch epochs, point-wise masks, metrology tables,
  markers, and component events in one `products.h5` with the run's
  provenance as root attributes; HDF5.jl becomes a dependency.
- Run provenance records the package version and the git commit of the
  checkout (`[provenance.platform]`).
- Scheduled generation gaps: `[[disruption.events]]` gain `affects =
  "link" | "generation"` (`antenna_repointing` defaults to generation);
  a generation event stops production for its duration, bounded by
  `gap_start` / `gap_end` rows with Batch = `SCHEDULED`.
- On-board recorder ceiling: `storage.onboard_capacity_days` (default 14)
  bounds the buffer in batches; the emitter discards new batches at the
  ceiling (no eviction) and records the loss as a `RECORDER` gap;
  validation warns when the initial blind spot or the longest contact gap
  exceeds the capacity; the mission summary and session figures shade
  scheduled gaps and recorder overflows and draw the reached capacity;
  the banner reports the capacity in batches and gigabit when the link is
  given as rates. The shipped scenario gains a 15-minute antenna
  repointing on day 1.5.
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

### Changed
- Documentation currency for 1.0.0: the interfaces page states every column
  of every product as the writers produce it (metrics profile, metrology
  tables, component events, point-wise masks, batch epochs), the complete
  event vocabularies with the `Attempt` semantics, the `[provenance.platform]`
  table, the heartbeat deletion on exit, the `HALT` removal before
  post-processing, and the `plots/` and `publication/` products; the manual
  index lists the current capabilities; the README gains a component-status
  table and drops the stale logging and count-delta claims; the changelog
  block is consolidated to one heading per category; CLI wrappers report
  errors through the logging macros.
- Dependency Manifests of the package and of the test, docs, scripts, and
  bench environments re-resolved on Julia 1.13.0 (patch updates taken; the
  test and root Manifests agree again); `SHA` compat widened to `"0.7, 1"`
  for the stdlib version shipped with 1.13; CI tests the 1.12 compat floor
  as a second blocking job.
- `Receiver.generate_mission_plots`, `plot_mission_summary`,
  `plot_session`, `Metrology.plot_alert_latency`, and `plot_delivery_delay`
  take `style`, `plots_dir`, `formats`, and `suffix` keywords (defaults
  reproduce the previous output); `generate_mission_plots` returns the
  paths written; the metrology plots accept `write_tables = false`.
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
  honor a redirected `DATA_ROOT`), and the latter loads the package instead
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

### Removed
- The pre-1.0 configuration aliases `simulation.test_duration_sec`,
  `simulation.max_storage_gb`, `physics.signal_injection_probability`,
  `post_processing.generate_batch_matrix`, and the `[disaster]` section name:
  a configuration carrying one is rejected with a `[CONFIG]` error naming the
  replacement (`TelemetryCore.reject_removed_key`, `reject_removed_section`);
  `aliased_value` is gone. Legacy run-artifact read paths (profile column
  normalization, snapshot fallbacks) are unchanged.
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
- `DataSegment.is_signal` and the instrument's per-segment signal flag:
  event instants are markers, not random draws. The synthetic noise
  realization of a given seed changes (one fewer RNG draw per segment).

### Fixed
- Figure legends size their rows from the entry widths (Makie packs a
  horizontal legend column-major), so the mission summary with the recorder
  bank no longer runs past the right figure edge at the design width; the
  day ticks of long missions are thinned to at most eleven labels.
- `bench/benchmarks.jl` runs again against the current API: the exact replay
  is `Receiver.reconstruct_batch_states` (renamed in the schema pass), the
  segment fixture drops the removed flag argument of `DataSegment`, and the
  benchmark configurations declare the storage budget under `[storage]` instead
  of the deprecated `simulation.max_storage_gb` alias.
- `VirtualInstrument.lisa_noise_psd` now implements the sky-averaged LISA
  sensitivity of Robson, Cornish & Liu (2019) exactly: the instrument term
  gains the 10/3 prefactor and the (1 + 0.6 (f/f*)²) response factor, and
  the galactic-confusion foreground follows their Eq. 14 with the Table 1
  fit selected by the new `physics.confusion_observation_years` (0.5 | 1.0 |
  2.0 | 4.0, default 1.0); the previous form misused the one-year β as an
  exponent and vanished above ≈ 0.2 mHz. The function returns `Inf` at
  `f ≤ 0` instead of a floor, and the synthesis zeroes every bin below the
  new `physics.noise_f_min_hz` (default 10⁻⁵ Hz). The calibration
  `E|X_k|² = S(f_k) f_s M/2` is unchanged; seeded streams change their
  amplitude spectrum. Observable only for `segment_duration_sec ≳ 2000 s`
  (60 s segments resolve no bin below 8.3 mHz).
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

### Changed
- Renamed (2026-08-02, recorded here for consumers): the package, module, and
  repository **SpaceTelemetrySim → DeepSpaceTelemetry** — a breaking change
  for any code `using` the old module name.

[Unreleased]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v0.9.0...v1.0.0
[0.9.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/releases/tag/v0.9.0
