# DeepSpaceTelemetry

[![CI](https://github.com/PaulGoG/DeepSpaceTelemetry.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/PaulGoG/DeepSpaceTelemetry.jl/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/PaulGoG/DeepSpaceTelemetry.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/PaulGoG/DeepSpaceTelemetry.jl)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Julia framework simulating the telemetry environment of deep-space science
missions: duty-cycled Deep Space Network (DSN) contact windows, prioritized
near-real-time (FIFO) transmission with LIFO archival backfill, stochastic
packet loss (Bernoulli / Gilbert–Elliott channels with retransmission), and
scheduled link-disruption events (blackouts with recovery ramps and elevated
loss). The telemetry, channel, and queuing layers are mission-agnostic; the
shipped scenarios and the synthetic physics payload model the LISA (Laser
Interferometer Space Antenna) mission, and external instrument data ingests
through the same pipeline.

---

## Project Structure

```text
DeepSpaceTelemetry/
├── src/
│   ├── DeepSpaceTelemetry.jl     # Main module
│   ├── TelemetryCore.jl         # Configuration (+validation), I/O, timers, event logs
│   ├── ChannelEffects.jl        # Packet-loss channels, disruption timeline, LinkModel
│   ├── VirtualInstrument.jl     # Calibrated strain synthesis and noise PSD (seeded RNG)
│   ├── PlotTheme.jl             # CairoMakie theme and styling
│   ├── Emitter.jl               # Satellite state machine (payload/queues)
│   ├── Receiver.jl              # DSN ground station, loss handling, post-processing
│   ├── Metrology.jl             # Event-log metrics: alert-latency curves (LIFO vs FIFO drain)
│   ├── Export.jl                # HDF5 product export (products.h5 with provenance attributes)
│   ├── Publication.jl           # Publication figure export at a declared printed width
│   └── Supervisor.jl            # Mission orchestration: plan, supervised tasks, sentinels
├── scripts/
│   ├── Project.toml             # Script environment (UI/log deps; parent package dev'ed)
│   ├── Manifest.toml            # Resolved script environment (committed for portability)
│   ├── launch_dashboard.jl      # Interactive entry point (live viewer + log terminals)
│   ├── run_full_sim.jl          # Headless entry point ([run_id] [config.toml]) → Supervisor.run_mission
│   ├── live_viewer.jl           # Terminal UI entry point, separate process (incl. Lost row)
│   ├── follow_log.jl            # Pure-Julia log follower for the dashboard terminals
│   ├── postprocessing/
│   │   ├── apply_telemetry_mask.jl      # Point-wise mask expansion (snapshot-aware)
│   │   ├── export_hdf5.jl               # HDF5 product export of a run
│   │   ├── export_publication_figures.jl # Vector figures at journal width + provenance sidecar
│   │   ├── generate_gif.jl              # Batch-routing animation engine
│   │   └── standalone_mask_expander.jl  # Dependency-light copy for collaborators
│   └── maintenance/
│       ├── generate_example_strain.jl   # Example external-input generator
│       └── cleanup.jl                   # Run-directory purger (asks for confirmation)
├── test/
│   ├── Project.toml             # Test environment (QA deps; parent package dev'ed at ../)
│   ├── Manifest.toml            # Resolved test environment (committed for portability)
│   └── runtests.jl              # Static QA + unit + physics + 4 integration suites
├── bench/
│   ├── Project.toml             # Benchmark environment (BenchmarkTools; parent dev'ed)
│   ├── Manifest.toml            # Resolved benchmark environment
│   └── benchmarks.jl            # Performance benchmarks (incl. channel hot paths)
├── docs/
│   ├── Project.toml             # Docs environment (Documenter; parent package dev'ed)
│   ├── Manifest.toml            # Resolved docs environment (committed for portability)
│   ├── make.jl                  # Documenter.jl build script
│   └── src/                     # Manual pages (index, physics, usage, interfaces, api/ per module)
├── scenarios/
│   ├── README.md                # Coverage matrix and expected regime of every scenario
│   ├── smoke_1d.toml            # 12 s smoke run (suite end-to-end)
│   ├── nominal_8h.toml          # Balanced nominal operations
│   ├── stress_8h_bursty.toml    # 8 h January passes, bursty loss, disruptions: backlog growth
│   ├── recovery_12h_seasonal.toml # Reference scenario (= config.toml): seasonal-peak recovery
│   ├── abstraction_gaussian_peak.toml # Pre-library default: 60 batches/h peak, Gaussian profile
│   ├── backlog_recovery_sine.toml # Presentation scenario: 3-day backlog, 10 % loss
│   ├── drop_policy.toml         # 20 % loss without retransmission
│   ├── explicit_schedule.toml   # Explicit pass list with missed, shortened, extended passes
│   ├── long_30d_seasonal.toml   # 30 days, contact gap reaching the recorder ceiling
│   ├── long_segments_confusion_band.toml # 2400 s segments resolving the confusion band
│   └── external_ingest.toml     # External CSV ingestion
├── data/
│   ├── example_external_strain.csv # Generated demo input (gitignored)
│   └── runs/                    # Ephemeral run directories (gitignored)
│       └── <RUN_ID>/            # onboard/ link/ ground/ lost/ plots/ masks/
│                                # + mission_profile.csv, events_tx.csv, events_rx.csv,
│                                #   component_events.csv, config_snapshot.toml,
│                                #   clock_anchor.toml, emitter.log, receiver.log,
│                                #   heartbeats and RUN_ACTIVE/RUN_COMPLETE/RUN_ABORTED
│                                #   sentinels (interfaces.md documents the full contract)
├── .github/workflows/CI.yml     # Test matrix + formatter + docs build (activates on remote)
├── .github/workflows/CompatHelper.yml # Weekly compat-bound update pull requests
├── .github/workflows/TagBot.yml # Release tags after registry merges (active once registered)
├── .github/dependabot.yml       # Monthly GitHub Actions version updates
├── .gitignore                   # Excludes run data and generated artifacts
├── .JuliaFormatter.toml         # Committed formatter configuration
├── CHANGELOG.md                 # Notable changes (Keep a Changelog format)
├── CITATION.cff                 # Citation metadata (Citation File Format 1.2.0)
├── CONTRIBUTING.md              # Working conventions: environments, tests, formatting, commits
├── config.toml                  # Default entry point (= scenarios/recovery_12h_seasonal.toml)
├── Project.toml                 # Package metadata, deps, compat bounds
├── Manifest.toml                # Resolved dependency graph (committed for portability)
├── LICENSE
└── README.md                    # Project documentation
```

---

## Obtaining the Package

Requires Julia ≥ 1.12 ([juliaup](https://github.com/JuliaLang/juliaup) is the
recommended installer). Clone the repository:

```bash
git clone git@github.com:PaulGoG/DeepSpaceTelemetry.jl.git
cd DeepSpaceTelemetry.jl
```

To consume the package as a library from another environment instead
(registration in General is pending):

```julia
using Pkg
Pkg.add(url = "https://github.com/PaulGoG/DeepSpaceTelemetry.jl")
```

---

## Environment Setup

All commands below are executed **from the package root** (the cloned
repository directory).
Relative config paths also resolve against the package root, so the scripts
work unmodified from any working directory.

`Project.toml` + `Manifest.toml` pin the full dependency graph; instantiating
them reproduces the exact tested environment on any machine:

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Every entry-point script also activates and instantiates the environment
automatically (silently), so this step is optional but avoids a first-run
delay.

---

## Usage & Execution

The satellite emitter, the ground receiver, and their supervisor run as
three cooperative tasks. Launch with `--threads=3` so each owns a thread
(`--threads=auto` is equivalent in effect; more threads bring no benefit).
On a single thread the pipeline still runs correctly, but compilation
warm-up, garbage collection, or figure rendering in one component pauses the
others until it yields; the entry point prints an advisory in that case.

### 1. Interactive Dashboard

Runs a fully interactive session with the live-viewer UI and background log
tailing:

```bash
julia --project=. --threads=3 scripts/launch_dashboard.jl
```

This spawns separate terminal windows for `emitter.log` and `receiver.log`
while rendering the simulation clock and the UnicodePlots dashboard in the
primary terminal.

### 2. Headless Pipeline (CI / Remote Clusters)

```bash
julia --project=. --threads=3 scripts/run_full_sim.jl
```

Any CLI argument ending in `.toml` selects an alternative configuration file
(relative paths resolve against the current directory, then the package root —
scenario configs may therefore live outside the repository); any other
argument sets the run ID (both optional, order-independent):

```bash
julia --project=. --threads=3 scripts/run_full_sim.jl MY_RUN path/to/scenario.toml
```

### 3. Post-Processing Tools

High-resolution `.gif` of a previous run (defaults to the latest):

```bash
julia --project=. scripts/postprocessing/generate_gif.jl [RUN_ID]
```

Manual expansion of 2D matrix rows into point-wise 0/1 arrays:

```bash
julia --project=. scripts/postprocessing/apply_telemetry_mask.jl [RUN_ID] 102400 100 output.csv
```

(Batches in state `4 = Lost` remain masked — a lost batch never becomes
available on the ground.)

HDF5 export of every product of a run (defaults to the latest):

```bash
julia --project=. scripts/postprocessing/export_hdf5.jl [RUN_ID]
```

Publication figures at the width and format of the run's
`[post_processing.publication]` settings, with a provenance sidecar:

```bash
julia --project=. scripts/postprocessing/export_publication_figures.jl [RUN_ID]
```

### 4. Tests & Benchmarks

The static-QA block (Aqua, ExplicitImports, JET), the unit and
physics-validation suites, and four end-to-end integration runs (lossless,
retention custodian, deterministic total-loss, and a headless mission
through the supervisor):

```bash
julia --project=. test/runtests.jl
```

(equivalently `julia --project=. -e 'using Pkg; Pkg.test()'`)

Performance benchmarks (`BenchmarkTools.jl`), including the ns-scale channel
hot paths:

```bash
julia --project=. bench/benchmarks.jl
```

### 5. Maintenance Utilities

Regenerate the example external-input series consumed when
`physics.data_source = "external"`:

```bash
julia --project=. scripts/maintenance/generate_example_strain.jl
```

Purge all previous run directories (lists candidates and asks for
confirmation; `--yes` skips the prompt in non-interactive contexts):

```bash
julia --project=. scripts/maintenance/cleanup.jl
```

### 6. Building the Manual

```bash
julia --project=docs docs/make.jl
```

renders the Documenter.jl manual (physics, usage, analysis interfaces, API
reference) into `docs/build/`. The manual is not deployed while the repository
is private; the CI docs job builds it as a check, and GitHub Pages deployment
is added at publication.

---

## Configuration

The framework is driven entirely by TOML files, free of hardcoded parameters.
**Safe parameter intervals are documented inline, key by key, in every
configuration file** and enforced at startup by `validate_config` (hard
`error` for code-breaking values, `@warn` for suspicious ones). A scenario
library ships under `scenarios/`: eleven complete configurations, from a
12-second smoke run to a 30-day seasonal mission, covering the physical
link rates and the peak-capacity abstraction, bursty and memoryless
channels, the drop policy, explicit pass schedules, the recorder ceiling,
long segments that resolve the galactic-confusion band, and external
ingestion; the coverage matrix with the expected regime of each file is
`scenarios/README.md`. `config.toml` at the package root is the default
entry point, a copy of the reference scenario
`scenarios/recovery_12h_seasonal.toml` (7 mission days at the seasonal peak
on the physical link, 2-day backlog, Gilbert–Elliott loss, three disruption
events, one marker, ~3 min wall time; rationale in `docs/src/usage.md`
§Scenario Library). Every run archives the exact configuration it used as
`config_snapshot.toml`, so provenance never depends on the driving file's
location.

Key sections (see the inline comments for the full safe-interval reference):

```toml
[simulation]        # speed_up, mission span, backlog, rng_seed
[storage]           # disk + inode budgets for the run directory, estimator calibration
[retention]         # the retention custodian: grace window, watermark, log rotation
[telemetry]         # daily DSN session window, capacity, bandwidth profile
[physics]           # data source, sample rate, segment/batch geometry
[packet_loss]       # enabled, model (bernoulli | gilbert_elliott), probabilities,
                    # on_loss (retransmit | drop), max_retries
[disruption]        # [[disruption.events]]: start_day, duration_hours, severity,
                    # recovery_hours, loss_multiplier (+ optional type, label)
[dashboard]         # which auxiliary terminals to spawn
[post_processing]   # mask matrix + point-wise expansions (target_event_rows)
```

`target_event_rows` accepts the string `"all"` (or `["all"]`), integer row
indices (`-1` selects the final row), and `"start:stop"` range strings, mixed
freely — e.g. `[-1, "10:20", 45]`.

---

## Key Features

*   **Continuous physics engine**: generates amplitude-calibrated synthetic
    LISA strain (`VirtualInstrument.jl`) via windowed overlap-add FFT
    synthesis — the stream is phase-continuous across segments and reproduces
    the sky-averaged LISA sensitivity of Robson, Cornish & Liu (2019), with a
    selectable galactic-confusion fit, at the correct absolute level — or ingests external
    continuous CSV time series without gaps or duplication across the
    pre-population boundary. All stochastic draws are seeded from
    `simulation.rng_seed`.
*   **Dynamic bandwidth profiling**: models the horizon-to-horizon satellite
    pass using `sine`, `sigmoid`, `gaussian`, or `flat` capacity profiles.
*   **Contact schedule** (`[contacts]`): seasonal pass-duration modulation,
    per-date exceptions (missed or shortened passes), explicit pass lists
    (TOML or CSV), and low-latency periods — extra contacts at a
    station-availability capacity fraction outside the nominal pass, each
    with its own session figure.
*   **Event markers** (`[[events.markers]]`): declared event instants,
    stamped into the batch metadata and the transmit event log when the
    holding batch is finalized; the alert-latency metric is evaluated at
    each marker, optionally triggering a low-latency period, with the
    `[ground]` processing budget reported on top.
*   **Scheduled generation gaps and the on-board recorder**: disruption
    events with `affects = "generation"` (antenna repointing) interrupt
    data production instead of the link; `storage.onboard_capacity_days`
    bounds the recorder without eviction, discarding new data at the
    ceiling and recording the loss as a gap.
*   **HDF5 product export** (`Export.jl`): every product of a run — event
    logs, metrics, masks, metrology tables, markers — in one
    self-describing `products.h5` with the run's provenance (package
    version, git commit, platform, configuration) as attributes.
*   **Publication figure export** (`Publication.jl`): every figure
    re-rendered at a declared printed width (double or single column) in
    PDF or SVG, text floored at 7 pt, into one directory with a
    `PROVENANCE.toml` sidecar tracing each panel to its run, commit, and
    configuration.
*   **Metrology** (`Metrology.jl`), from the event logs: the alert-latency
    curve — how long after a live event the look-back window `δ` is on the
    ground, realized live-FIFO/archive-LIFO doctrine against a
    counterfactual FIFO drain over the same service completions — and the
    measurement-to-ground delivery delay of every batch against a
    requirement (LISA: 24 h). Link capacity is configured either as
    batches per hour or as downlink and on-board data rates.
*   **Stochastic packet loss** (`ChannelEffects.jl`): every downlink transfer
    attempt draws from a configurable channel model — memoryless **Bernoulli**
    or bursty two-state **Gilbert–Elliott** (validated against its analytic
    stationary rate). Failed transfers are retried (`on_loss = "retransmit"`,
    head-of-line blocking) up to `max_retries`, then the batch moves to
    `lost/` — data preserved, never deleted.
*   **Disruption events**: `[[disruption.events]]` schedules link-degrading
    events (solar flares, safe-mode entries, station outages): full or partial
    blackout (`severity`), a linear `recovery_hours` capacity ramp, and
    `loss_multiplier`-elevated stochastic loss while active. Onboard backlog
    accumulation and the post-event LIFO drain emerge from the standard
    queuing mechanics.
*   **FIFO/LIFO routing**: live data is transmitted immediately (FIFO) for
    zero-latency situational awareness; the blind-spot backlog is downlinked
    LIFO (newest first), so the data most tightly coupled to the live stream
    is recovered first.
*   **Ground-truth event logs**: emitter and receiver append every batch
    milestone (`gen`, `tx`, `ingested`, `retry`, `lost`) to `events_tx.csv` /
    `events_rx.csv`; post-processing replays them for an **exact** batch-state
    reconstruction (legacy runs fall back to the count-delta heuristic).
*   **2D telemetry mask matrices**: tracks the state of every batch across
    time (`0=Future, 1=Onboard, 2=Link, 3=Ground, 4=Lost`) in
    `telemetry_mask_timeline.csv`.
*   **Validated, self-documenting configuration**: every key in `config.toml`
    carries its safe interval inline; `validate_config` aborts on
    code-breaking values with a precise `[CONFIG]` message and warns on
    suspicious ones before any data is generated. All coercions are
    type-checked; malformed TOML is reported with its parse error; a corrupt
    `config_snapshot.toml` falls back to the project config with a warning.
*   **Failure-isolated post-processing**: plots, mask matrices, and point-wise
    expansions each run inside their own guard — an error in any product is
    reported (`@error` + stacktrace) but never aborts the remaining stages or
    costs completed run data.
*   **Terminal dashboards**: zero-flicker, change-driven terminal UI
    (`UnicodePlots.jl`) with live disruption/loss status lines, alongside
    background `.log` tracking (`TerminalLoggers` + `LoggingExtras`, file logs
    ANSI-sanitized).
*   **Publication-oriented outputs**: static figures as vector `.pdf` plus
    raster `.png` (nominal vs
    effective bandwidth, disruption-window shading fading across the recovery
    ramp, a lost-batch strip on the mission summary, ✕ loss pins with count
    badges on lossy session plots, one frameless figure-level legend
    restricted to what each figure draws) and chronological `.gif` animations
    (legend strip; dedicated Lost row in lossy runs) via `CairoMakie.jl`.
    Time axes are 0-based elapsed mission days anchored at `start_sim_time`
    ("Day k" = start + k·24 h, matching `disruption.start_day`).
*   **Data provenance**: every run directory
    receives a `config_snapshot.toml` which all post-processing reads back
    (never the live `config.toml`), and result CSVs are written with
    `safesave`-style `#k` backup rotation.

---

## Architecture Summary

Two asynchronous tasks exchange physical batch directories through a
file-system broker, coordinated only by the shared accelerated clock:

1. **Emitter** (`src/Emitter.jl`) — generates 60 s strain segments
   (`src/VirtualInstrument.jl`), assembles them into batches under `onboard/`,
   stamps them `LIVE_` (generated during a DSN pass) or `ARCH_` (generated in
   a blind spot or blackout), and moves them to `link/` while the composite
   link (`src/ChannelEffects.jl`: visibility × disruption) is transmittable.
2. **Receiver** (`src/Receiver.jl`) — polls `link/`, applies the download
   delay implied by the current effective bandwidth, draws one stochastic
   loss realization per transfer attempt, and moves batches to `ground/`
   (or, after retry exhaustion, to `lost/`); leaving `link/` frees the
   emitter's in-flight slot.

The routing invariant mirrors the LISA operational concept: **live data is
transmitted FIFO with absolute priority; residual bandwidth backfills the
archive LIFO (newest first)**, so alert pipelines can extend a live event's
waveform backwards in time without temporal gaps. Every batch milestone is
appended to `events_tx.csv` / `events_rx.csv`, from which post-processing
reconstructs the exact per-batch state history (plots, animation, and the
0–4 mask matrix). External analysis pipelines (sliding-window searches, alert
generators) couple to a run exclusively through the filesystem — batch
directories delivered by atomic `mv`, append-only event feeds, and the mask
products — under a read/copy-only contract that admits any number of
concurrent consumer instances; see `docs/src/interfaces.md`. For the noise
model, channel models, and configuration reference, see `docs/src/physics.md`
and `docs/src/usage.md` (or build the manual, §6 above).

---

## Citing

Citation metadata is in `CITATION.cff` (Citation File Format 1.2.0). GitHub
renders it as a citation widget, and `cffconvert` turns it into BibTeX. Cite
the version used, by tag.

---

## Contributing

`CONTRIBUTING.md` states the working conventions: environment activation, the
test suite with its static-analysis checks, formatting, documentation,
configuration changes, and the commit and pull-request format.

---

## License

MIT — see `LICENSE`.
