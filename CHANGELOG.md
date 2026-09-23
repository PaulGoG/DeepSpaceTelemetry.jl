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
  dotted nominal-capacity curve; `Receiver.marker_times` reads the markers
  through `TelemetryCore.load_markers`.
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

[Unreleased]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/compare/v0.9.0...v1.0.0
[0.9.0]: https://github.com/PaulGoG/DeepSpaceTelemetry.jl/releases/tag/v0.9.0
