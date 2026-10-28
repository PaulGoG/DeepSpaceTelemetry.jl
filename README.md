# DeepSpaceTelemetry

[![Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/)
[![CI](https://github.com/PaulGoG/DeepSpaceTelemetry.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/PaulGoG/DeepSpaceTelemetry.jl/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/PaulGoG/DeepSpaceTelemetry.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/PaulGoG/DeepSpaceTelemetry.jl)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Julia framework simulating the telemetry environment of deep-space science
missions: duty-cycled deep-space-network (DSN) contact windows, prioritized
near-real-time (FIFO) transmission with LIFO archival backfill, stochastic
packet loss with retransmission, and scheduled link disruptions. The
telemetry, channel, and queuing layers are mission-agnostic; the shipped
scenarios model the LISA (Laser Interferometer Space Antenna) mission, and
external instrument data ingests through the same pipeline. Missions run
either on a wall-paced clock, accelerated or at mission cadence, for
rehearsals with live dashboards, or on a logical clock that makes a run
reproducible from its seed.

**[Manual](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/)** · [Physics](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/physics/) ·
[Configuration](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/usage/) · [Scenario gallery](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/gallery/) ·
[Analysis interfaces](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/interfaces/) · [Scenario library](scenarios/README.md) · [Changelog](CHANGELOG.md)

> "DSN" denotes throughout a deep-space ground-station network in the generic
> sense; the LISA passes are ESA ESTRACK 35 m antenna passes.

## Project structure

```text
DeepSpaceTelemetry/
├── src/            # The library: channel models, the instrument, emitter,
│                   #   receiver, metrology, HDF5 export, publication figures,
│                   #   the mission supervisor, and sweeps
├── reader/         # The reader package: configuration and I/O (TelemetryCore)
│                   #   and the run adapter for consumers, without the figure stack
├── scripts/        # Entry points (headless run, dashboard, sweeps) and post-processing
├── scenarios/      # Twelve complete configurations and their coverage matrix
├── test/           # Static QA, unit, physics, and four integration missions
├── bench/          # BenchmarkTools suites
├── docs/           # Documenter manual sources, the figures, and their render script
├── data/runs/      # Ephemeral run directories (gitignored)
├── activate.jl     # Activates and instantiates this environment (one per environment)
├── config.toml     # Default entry point (= scenarios/recovery_12h_seasonal.toml)
└── Project.toml    # Package metadata, deps, compat bounds
```

The [analysis interfaces](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/interfaces/)
page specifies the layout and file contract of a run directory.

![Mission summary of the stress scenario: seven daily passes against a
growing onboard buffer, an 18 h solar-flare blackout with a 12 h recovery
ramp, a partial ground-station outage, a scheduled generation gap, and an
event marker with its triggered low-latency
period](docs/src/assets/gallery/stress_8h_bursty_mission_summary_global.png)

One week of the shipped `scenarios/stress_8h_bursty.toml`: 8 h daily passes
on the physical link, a bursty Gilbert–Elliott channel, an 18 h solar-flare
blackout followed by a 12 h recovery ramp on day 2.5, a 12 h partial
ground-station outage on day 5, a scheduled generation gap on day 1.5, and
an event marker on day 4 whose triggered low-latency period opens six hours
later at half capacity. The link never recovers the disruption debt: the
onboard buffer grows from 288 to 530 batches over the week, while 760
batches reach the ground. Retransmission recovers all 49 rejected transfers,
and the lost-batch strip stays at zero. This is a tick-mode run, reproducible
from the scenario, the seed, and the commit recorded in
[`docs/src/assets/PROVENANCE.toml`](docs/src/assets/PROVENANCE.toml). The
[scenario library](scenarios/README.md#gallery) shows nine further scenarios
through the same figure.

## Installation

Requires Julia ≥ 1.12 ([juliaup](https://github.com/JuliaLang/juliaup) is the
recommended installer). Clone the repository:

```bash
git clone https://github.com/PaulGoG/DeepSpaceTelemetry.jl.git
cd DeepSpaceTelemetry.jl
```

A consumer that only reads run directories adds the reader package alone,
`Pkg.add(url = "https://github.com/PaulGoG/DeepSpaceTelemetry.jl", subdir = "reader")`,
and gets `TelemetryCore` and `RunAdapter` without the figure stack and the
HDF5 export; the two packages share one version.

The commands below are written for the package root, the cloned repository
directory. The scripts also run from any other working directory: a relative
config path not found there resolves against the package root. With no
configuration argument, a `config.toml` in the working directory takes
precedence over the package default.

Each entry-point script silently activates and instantiates its own
environment as its first statement, so nothing needs preparing and no
`--project` flag is passed. I do not track manifests: `Project.toml` with its
`[compat]` bounds defines each environment, and each run stores the manifest
it resolved as `manifest_snapshot.toml` in its run directory.

The same activation scripts open an interactive session:

```bash
julia -i activate.jl           # the package environment
julia -i test/activate.jl      # the test environment (Aqua, JET, StableRNGs, …)
julia -i docs/activate.jl      # Documenter
julia -i bench/activate.jl     # BenchmarkTools
julia -i scripts/activate.jl   # the entry points' environment (terminal UI, logging)
```

Each leaves a REPL with that environment active; from an existing REPL,
`include` the same file. The first instantiation of an environment resolves
and precompiles it, which is slow; later ones are no-ops.

## Usage and execution

The emitter, the receiver, and their supervisor are cooperative tasks of one
driver on one thread: mission time advances from one component wakeup to the
next, so a run reproduces its event logs and mask products to the byte for a
given seed on a given platform. In wall mode, the default, the driver paces
those wakeups against the wall clock, `simulation.speed_up` mission seconds
per wall second for `mission_wall_seconds`; the budget is nominal, since a
host that lags releases the next wakeup late and finishes later with the same
content. In tick mode (`simulation.mode = "tick"`, span `mission_days`) the
driver runs unpaced and a run takes as long as its events take to process; a
wall run and the tick run of the same configuration produce the same
record.

### Run a mission

Headless, on the default configuration:

```bash
julia scripts/run_full_sim.jl
```

The arguments are optional and order-independent. One ending in `.toml`
selects another configuration; a relative path resolves against the current
directory, then the package root, so scenario files may live outside the
repository. `--tick` runs the configuration on the tick clock with its span
unchanged, and any other argument sets the run ID:

```bash
julia scripts/run_full_sim.jl MY_RUN scenarios/stress_8h_bursty.toml
julia scripts/run_full_sim.jl --tick MY_RUN scenarios/stress_8h_bursty.toml
```

A sweep runs a configuration on the tick clock once per seed, optionally
with overrides and several runs at once on threads, and writes the realized totals of
all runs to `data/sweeps/<PREFIX>/summary.csv`, with the sweep's provenance
in `sweep.toml` beside it:

```bash
julia scripts/run_sweep.jl scenarios/stress_8h_bursty.toml MY_SWEEP --seeds 1:8 --workers 4 --set packet_loss.p_loss=0.2
```

Interactively, with the live viewer and the two log followers in their own
terminal windows:

```bash
julia scripts/launch_dashboard.jl
```

The mission itself runs in the primary terminal, which shows the supervisor's
banner and stage messages. The receiver's own console status panel is off by
default and enabled with `dashboard.receiver_status_panel = true`.

### Tests, benchmarks, and the manual

```bash
julia test/runtests.jl   # static QA, unit, physics, integration
julia bench/benchmarks.jl   # BenchmarkTools, incl. the channel hot paths
julia docs/make.jl       # the manual into docs/build/
```

The suite (equivalently `Pkg.test()`) runs the Aqua, ExplicitImports, and JET
checks, the unit and physics-validation testsets, four end-to-end
integration missions (lossless, retention custodian, deterministic total
loss, and a headless mission through the supervisor), and three tick
missions that test reproducibility: one seed twice, another once. Setting
`DEEPSPACETELEMETRY_TEST_INSTALLED=true` adds a run from a copy that Pkg
installs into a temporary depot, pinned by commit as a downstream consumer
pins it, and checks that run's source identity. The copy precompiles from
scratch, which adds several minutes.

The CI docs job publishes the manual at
<https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/> on every version
tag. It also deploys the build of `main` on every push, reachable from the
version selector at the top of any page.

<details>
<summary>Post-processing and maintenance commands</summary>

The post-processing commands read a completed run directory; those taking
`[RUN_ID]` default to the most recent run.

```bash
# Chronological animation of the batch routing (--web: README/manual size)
julia scripts/postprocessing/generate_gif.jl [--web] [RUN_ID]

# HDF5 export of every product of a run, provenance in the root attributes
julia scripts/postprocessing/export_hdf5.jl [RUN_ID]

# Figures at the width and format of [post_processing.publication], with a sidecar
julia scripts/postprocessing/export_publication_figures.jl [RUN_ID]

# Complete a run whose supervisor was killed during post-processing:
# recompute the products, settle RUN_ACTIVE (--force skips the recent-write test)
julia scripts/postprocessing/complete_run.jl <RUN_ID> [--force]

# Regenerate the example series for physics.data_source = "external"
julia scripts/maintenance/generate_example_strain.jl

# Regenerate the manual and README figures from fresh tick-mode runs of the
# scenario library (needs ImageMagick)
julia docs/render_assets.jl [RUN_ID_PREFIX]

# Purge previous run directories (lists candidates and asks; --yes skips the prompt)
julia scripts/maintenance/cleanup.jl
```

In the mask expansion, batches in state `4 = Lost` remain masked: a lost
batch never becomes available on the ground.

</details>

## Component status

| Component | Role | Status |
|---|---|---|
| `TelemetryCore` | configuration accessors and validation, run layout, batch I/O, event logs, provenance, the tick clock and its driver, paced or not | stable; unit, guardrail, scheduler, and static-QA coverage |
| `ChannelEffects` | loss channels, disruption timeline, composite link model | stable; validated against the analytic stationary loss rate |
| `VirtualInstrument` | binary flag payload declared by the event markers, external ingestion | stable; flag rule, boundary cases, clock advance, and the payload grid across gaps and restarts tested |
| `Emitter` / `Receiver` | spacecraft and ground-station state machines on the tick driver | stable; four end-to-end integration missions and the tick missions in the suite |
| `Masks` / `MissionFigures` | batch-state replay, mask products, the gap table; mission, session, and raster figures | stable; replay, gap-table, legend, and layout tests |
| `Metrology` | alert-latency and delivery-delay metrics | stable; synthetic-schedule tests |
| `Export` / `Publication` | HDF5 products, journal-width figure export with provenance | stable; round-trip and export tests |
| `Supervisor` | mission plan, supervised component tasks, failure policy, sentinels, banner | stable; restart, policy, and reproducibility tests |
| `RunAdapter` | reference run adapter over the file contract: geometry, batches, payload, arrivals, state, labeled intervals; byte-offset feed cursors, hole-feed reader, delivered rows, marker rows, producer-version check | since 2.5.0; tested against a lossy tick run with a generation gap and against the gap table |
| `Sweeps` | ensembles and parameter sweeps on the tick clock, serial or several runs at once on threads, with a summary table and provenance | since 2.5.0; a two-seed sweep in the suite, serial and concurrent, with identical tables |
| `PlotTheme` | figure theme and scale-aware styling | stable |
| Scenario library | twelve configurations under `scenarios/` | every file validated and the smoke scenario run by the suite; a shortened deterministic scenario run three times in the tick testset |
| Entry points | `run_full_sim.jl` (argument parsing, `--tick`, plus `Supervisor.run_mission`), `run_sweep.jl` (`Sweeps.run_sweep`), `launch_dashboard.jl`, `live_viewer.jl`, `follow_log.jl` | `run_full_sim.jl` verified on the shipped scenarios at each release and, through its library call, on the smoke scenario in the suite; the interactive dashboard, live viewer, and log follower verified manually |
| Post-processing wrappers | `complete_run.jl`, `export_hdf5.jl`, `export_publication_figures.jl`, `generate_gif.jl` | thin wrappers over tested library functions (`Supervisor.complete_run`, `Export.export_hdf5`, `Publication.export_publication_figures`); `generate_gif.jl` (over the tested `Masks.batch_states` replay) verified on the shipped scenarios at each release |
| Maintenance utilities | `generate_example_strain.jl`, `cleanup.jl`, `docs/render_assets.jl` | `generate_example_strain.jl` verified through `scenarios/external_ingest.toml` at each release; `cleanup.jl` (confirmation prompt) verified manually; `render_assets.jl` run end to end at every figure regeneration |

<details>
<summary>Full file tree, annotated</summary>

```text
DeepSpaceTelemetry/
├── src/
│   ├── DeepSpaceTelemetry.jl    # Main module
│   ├── ChannelEffects.jl        # Packet-loss channels, disruption timeline, LinkModel
│   ├── VirtualInstrument.jl     # Payload: binary flag series or external CSV ingestion
│   ├── PlotTheme.jl             # CairoMakie theme and styling
│   ├── Emitter.jl               # Satellite state machine (payload/queues)
│   ├── Receiver.jl              # DSN ground station loop, loss handling, retention
│   ├── Masks.jl                 # Batch-state replay, mask timeline, gap table
│   ├── MissionFigures.jl        # Mission summary, session figures, batch-state raster
│   ├── Metrology.jl             # Metrics: alert latency (LIFO vs FIFO drain), delivery delay
│   ├── Export.jl                # HDF5 product export (products.h5 with provenance attributes)
│   ├── Publication.jl           # Publication figure export at a declared printed width
│   ├── Supervisor.jl            # Mission orchestration: plan, supervised tasks, sentinels
│   └── Sweeps.jl                # Ensembles and sweeps on the tick clock
├── reader/                      # DeepSpaceTelemetryReader, versioned with this package
│   ├── Project.toml             # Reader package: CSV, DataFrames, JSON, TOML, SHA and stdlib only
│   ├── activate.jl              # Activates and instantiates the reader environment
│   └── src/
│       ├── DeepSpaceTelemetryReader.jl # Module header; exports TelemetryCore and RunAdapter
│       ├── TelemetryCore.jl     # Module header; includes the files below in dependency order
│       ├── TelemetryCore/       # Layout, Config, Validation, Timing, Storage, Clocks, EventLogs,
│       │                        #   HoleFeed, TableIO, Provenance, BatchIO, Visibility
│       └── RunAdapter.jl        # Reference run adapter: file-contract reader, feed cursors, markers, label spans
├── scripts/
│   ├── Project.toml             # Script environment: terminal UI and logging; package by path via [sources]
│   ├── activate.jl              # Activates and instantiates the script environment
│   ├── launch_dashboard.jl      # Interactive entry point (live viewer + log terminals)
│   ├── run_full_sim.jl          # Headless entry point ([run_id] [config.toml] [--tick]) → Supervisor.run_mission
│   ├── run_sweep.jl             # Sweep entry point (<config> <PREFIX> --seeds --workers --set) → Sweeps.run_sweep
│   ├── live_viewer.jl           # Terminal UI entry point, separate process (incl. Lost row)
│   ├── follow_log.jl            # Pure-Julia log follower for the dashboard terminals
│   ├── postprocessing/
│   │   ├── complete_run.jl              # Post-processing and sentinels of a stranded run
│   │   ├── export_hdf5.jl               # HDF5 product export of a run
│   │   ├── export_publication_figures.jl # Vector figures at journal width + provenance sidecar
│   │   └── generate_gif.jl              # Batch-routing animation engine
│   └── maintenance/
│       ├── generate_example_strain.jl   # Example external-input generator
│       └── cleanup.jl                   # Run-directory purger (asks for confirmation)
├── test/
│   ├── Project.toml             # Test environment: QA dependencies; package by path via [sources]
│   ├── activate.jl              # Activates and instantiates the test environment
│   └── runtests.jl              # Entry point; includes test/<subject>.jl (installed_copy.jl opt-in)
├── bench/
│   ├── Project.toml             # Benchmark environment: BenchmarkTools; package by path via [sources]
│   ├── activate.jl              # Activates and instantiates the benchmark environment
│   └── benchmarks.jl            # Performance benchmarks (incl. channel hot paths)
├── docs/
│   ├── Project.toml             # Docs environment: Documenter; package by path via [sources]
│   ├── activate.jl              # Activates and instantiates the docs environment
│   ├── make.jl                  # Documenter.jl build script
│   ├── render_assets.jl         # Runs the gallery scenarios and renders the figures below
│   └── src/                     # Manual pages
│       ├── index.md             # Overview, installation, capabilities
│       ├── physics.md           # Payload, link capacity, channels, queuing, metrology
│       ├── usage.md             # Configuration reference and execution
│       ├── gallery.md           # Ten scenarios through the figures of one run each
│       ├── interfaces.md        # Filesystem contract for analysis pipelines
│       ├── api.md               # API reference index
│       ├── api/                 # Fourteen per-module API pages
│       └── assets/              # gallery/ (figures of the manual and the README) and PROVENANCE.toml
├── scenarios/
│   ├── README.md                # Coverage matrix, expected regime, and mission summary of every scenario
│   ├── smoke_1d.toml            # 12 s smoke run (suite end-to-end)
│   ├── nominal_8h.toml          # Balanced nominal operations
│   ├── stress_8h_bursty.toml    # 8 h January passes, bursty loss, disruptions: backlog growth
│   ├── recovery_12h_seasonal.toml # Reference scenario (= config.toml): seasonal-peak recovery
│   ├── abstraction_gaussian_peak.toml # Pre-library default: 60 batches/h peak, Gaussian profile
│   ├── backlog_recovery_sine.toml # Backlog recovery under retransmission load: 3-day backlog, 10 % loss
│   ├── drop_policy.toml         # 20 % loss without retransmission
│   ├── explicit_schedule.toml   # Explicit pass list with missed, shortened, extended passes
│   ├── long_30d_seasonal.toml   # 30 days, contact gap reaching the recorder ceiling
│   ├── long_segments_2400s.toml # 2400 s segments: the coarse-batch regime
│   ├── external_ingest.toml     # External CSV ingestion
│   └── deterministic_1d.toml    # One mission day on the tick clock
├── data/
│   ├── example_external_strain.csv # Generated demo input (gitignored)
│   └── runs/                    # Ephemeral run directories (gitignored)
│       ├── .gitkeep             # Keeps the directory in git
│       └── <RUN_ID>/            # Run products; the analysis interfaces page documents the contract
├── .github/workflows/CI.yml     # Test matrix (Linux 1.12 / 1 / pre, macOS and Windows on 1), formatter, docs build and deployment
├── .github/dependabot.yml       # Weekly Julia and GitHub Actions version updates
├── .github/ISSUE_TEMPLATE/      # Bug-report and feature-request forms
├── .github/PULL_REQUEST_TEMPLATE.md # Change, verification, open points
├── activate.jl                  # Activates and instantiates the package environment
├── .gitattributes               # LF in the object database (Windows CI checkouts)
├── .gitignore                   # Excludes run data and generated artifacts
├── .JuliaFormatter.toml         # Committed formatter configuration
├── CHANGELOG.md                 # Notable changes (Keep a Changelog format)
├── CITATION.cff                 # Citation metadata (Citation File Format 1.2.0)
├── codecov.yml                  # Coverage thresholds and excluded paths
├── CONTRIBUTING.md              # Working conventions: environments, tests, formatting, commits
├── config.toml                  # Default entry point (= scenarios/recovery_12h_seasonal.toml)
├── Project.toml                 # Package metadata, deps, compat bounds
├── LICENSE
└── README.md                    # Project documentation
```

</details>

## Configuration

Mission parameters are set in TOML files. Each key carries its safe interval
in an inline comment, and `validate_config` enforces these intervals at
startup, before any data is generated: code-breaking values are a hard
error, suspicious ones a warning. A run archives the configuration it used
as `config_snapshot.toml`, so its provenance does not depend on where the
driving file lives.

`config.toml` at the package root is the default entry point, a copy of the
reference scenario `scenarios/recovery_12h_seasonal.toml`: 7 mission days at
the seasonal peak on the physical link, a 2-day backlog, Gilbert–Elliott
loss, three disruption events, one marker, about 3 minutes of wall time.
Eleven further scenarios ship beside it, from a 12-second smoke run to a
30-day seasonal mission; the [coverage matrix](scenarios/README.md) states
what each one exercises and the regime it produces.

<details>
<summary>Configuration sections</summary>

```toml
[simulation]        # mode (wall | tick), speed_up and wall span or mission_days, backlog, rng_seed
[supervision]       # component-failure policy, restart budget
[storage]           # disk, inode, and RAM budgets of the run directory
[retention]         # the retention custodian: grace window, watermark, log rotation
[telemetry]         # daily DSN session window, capacity, bandwidth profile, recorder size
[contacts]          # seasonal modulation, exceptions, explicit passes, low-latency periods
[physics]           # data source, sample rate, segment/batch geometry
[ground]            # processing budget added to every alert latency
[packet_loss]       # enabled, model (bernoulli | gilbert_elliott), probabilities,
                    # on_loss (retransmit | drop), max_retries
[disruption]        # [[disruption.events]]: start_day, duration_hours, severity,
                    # recovery_hours, loss_multiplier (+ optional affects, type, label)
[events]            # [[events.markers]]: declared event instants
[dashboard]         # auxiliary terminals to spawn, receiver status panel on the console
[post_processing]   # mask matrix, metric and figure flags,
                    # session-figure switch and cap, HDF5 and publication export
```

A configuration written for 2.x that `validate_config` rejects names the
key and its remedy; the manual's Upgrading page lists the changes of 3.0.
The
[configuration reference](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/usage/) documents every key.

</details>

## Capabilities

- **Link and contacts** — the pass profile (`sine`, `sigmoid`, `gaussian`,
  `flat`) or the physical rate pair (`downlink_kbps`,
  `onboard_data_rate_kbps`); seasonal pass-duration modulation, per-date
  exceptions for missed and shortened passes, explicit pass lists in TOML or
  CSV, and low-latency periods at a station-availability capacity fraction.
- **Two clocks** — one driver: wall mode paces it against the wall clock,
  for rehearsals with the live dashboards; tick mode runs it unpaced. Both
  reproduce a run for a given seed on a given platform, and both write the
  same record for the same configuration.
- **FIFO/LIFO routing** — live data is transmitted immediately with absolute
  priority; the blind-spot backlog is downlinked newest-first, so the data
  most tightly coupled to a live event is recovered first.
- **Loss and disruption** — every transfer attempt draws from a memoryless
  Bernoulli or a bursty two-state Gilbert–Elliott channel, the latter
  validated against its analytic stationary rate. Retransmission is deferred
  by the round-trip light time while the other in-flight batches keep being
  served, and ends after
  `max_retries`, at which point the batch moves to `lost/` rather than being
  deleted. Scheduled disruptions apply a full or partial blackout, a linear
  recovery ramp, and elevated loss. Generation gaps stop production instead
  of the link, and at the on-board recorder ceiling new data is discarded
  and recorded as a gap.
- **Payload** — a binary flag series, `1` on the segments that hold a
  declared event marker and `0` elsewhere, so a delivery mask applied to it
  states which samples of an event have reached the ground; or ingestion of
  an external continuous CSV series, one or several of its columns as one
  payload under one link accounting. The packet-loss channel, the run's only
  random stream, is seeded from `simulation.rng_seed`.
- **Metrology** — the alert-latency curve, giving the time after a live event
  at which the look-back window δ is complete on the ground under the
  realized doctrine against a counterfactual FIFO drain over the same service
  completions; and the measurement-to-ground delivery delay of every batch
  against a requirement (24 h for LISA). Declared event markers are stamped
  into the batch metadata and the alert latency is evaluated at each of them.
- **Consumers and ensembles** — the reference run adapter answers what a
  consumer asks of a run (geometry, batches, payload, arrivals, state,
  labeled intervals) from the file contract, declares holes as the feeds
  announce them, and checks the producer's version. A sweep gathers the
  totals of a seed ensemble on the tick clock into one table with its
  provenance. Each run ends with a descriptor that a downstream collection
  copies as its source identity.
- **Data products** — append-only emitter and receiver event logs, from which
  post-processing replays the exact per-batch state history; the 0–4 mask
  timeline and the delivered payload rows at any instant; the gap table,
  every hole
  of the delivered record as a payload-row interval with its cause (lost,
  pruned, undelivered, a generation gap by type, an unreached record); the
  label-span table, every labeled interval of the scenario on the same grid;
  the declared-hole feed, to which the producer appends the same holes as it
  declares them, settled with the end-of-run holes; the metrics profile; the
  batch-state raster, which shows the LIFO backfill advancing backward in
  batch identifier; an HDF5 export of every product with the run's
  provenance as attributes; publication figures at a declared printed width
  with a provenance sidecar; and a chronological animation.
- **Provenance and safety** — every run archives its configuration snapshot,
  the manifest it was resolved on, the platform fingerprint, and the git
  commit with a flag for uncommitted changes; results are written with
  `safesave`-style `#k` backup rotation; and each post-processing product
  runs inside its own guard, so one failure costs neither the others nor the
  completed run data.
- **Monitoring** — a change-driven `UnicodePlots` terminal viewer with live
  disruption and loss status lines, beside size-rotated `.log` files kept
  free of ANSI sequences.

## Architecture summary

Two asynchronous tasks exchange physical batch directories through a
file-system broker, coordinated only by the shared mission clock, wall-paced
or logical:

1. **Emitter** (`src/Emitter.jl`) — generates payload segments, assembles them
   into batches under `onboard/`, stamps them `LIVE_` (generated during a
   pass) or `ARCH_` (generated in a blind spot or blackout), and moves them
   to `link/` while the composite link, visibility times disruption, is
   transmittable.
2. **Receiver** (`src/Receiver.jl`) — polls `link/`, applies the download
   delay implied by the current effective bandwidth, draws one loss
   realization per transfer attempt, and moves batches to `ground/` or, after
   retry exhaustion, to `lost/`; leaving `link/` frees the emitter's
   in-flight slot.

The routing invariant mirrors the LISA operational concept: **live data is
transmitted FIFO with absolute priority; residual bandwidth backfills the
archive LIFO (newest first)**, so alert pipelines can extend a live event's
waveform backward in time without temporal gaps.

![Batch-routing animation: one row per stage, sky blue for live batches and
green for archive ones, with the mission clock and the buffer counters in
every frame](docs/src/assets/gallery/stress_8h_bursty_telemetry_animation_web.gif)

The same run, batch by batch. The rows are the stages: buffered on the
satellite, in flight on the link, delivered on the ground. Color gives the
routing family, sky blue for live (FIFO) and green for archive (LIFO), and
the marker shape repeats the distinction. Live batches cross as they are generated,
so the sky-blue runs mark the passes, and between them the archive segment
grows backward in batch identifier, contiguous with the live tail. Through
the blackout the ground row stands still while the onboard block extends to
the right. Each frame states the mission clock, the link state, and the
onboard and ground counts.

External analysis pipelines couple to a run only through the filesystem:
batch directories delivered by atomic `mv`, append-only event feeds, and the
mask products. The contract is read/copy-only and admits any number of
concurrent consumers. The
[analysis interfaces](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/interfaces/) page specifies every file and column and gives a
worked reader for each of the two consumer classes: a streaming consumer
follows an active run through its arrival feed, a stationary consumer opens
a finished run as a fixed record with its gaps declared.

## Public surface and versioning

The public surface is the run-directory file contract (the manual's
interfaces page), the configuration schema (`config.toml` and the keys the
manual documents), and the entry-point scripts under `scripts/`. Semantic
versioning applies to that surface: a change that alters what a consumer
reads from a run directory, rejects a configuration that was accepted, or
changes a script's arguments or products is a major release. The Julia
modules and their functions are the implementation; they may move or change
between minor releases, and the API reference documents them for
contributors. The one exception is `RunAdapter`: its types, its version
floor and its functions follow the file contract and are versioned with it.
They are declared `public` (not exported), so a consumer's qualified access
passes ExplicitImports' `check_all_qualified_accesses_are_public`.

Since 3.0 the package is maintained rather than extended: patch releases fix
defects and keep the dependencies current. Anything removed from the public
surface first warns through at least one minor release. The supported Julia
versions are 1.12 and the current stable release; defects are reported as
GitHub issues. The manual's
[Upgrading](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/upgrading/)
page lists the changes from 2.x.

## How to cite

Citation metadata is in `CITATION.cff`, which GitHub renders as a citation
widget. Cite the version used, by tag:

```bibtex
@software{DeepSpaceTelemetry,
  author  = {Gogîță, Paul-Adrian},
  title   = {DeepSpaceTelemetry.jl: a telemetry, channel, and queuing simulator for deep-space science missions},
  year    = {2026},
  version = {3.0.0},
  url     = {https://github.com/PaulGoG/DeepSpaceTelemetry.jl}
}
```

## Contributing, license

`CONTRIBUTING.md` states the working conventions, from environment
activation and the test suite to the commit and pull-request format. The
package is MIT-licensed; see `LICENSE`.
