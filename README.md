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
scenarios and the synthetic payload model the LISA (Laser Interferometer
Space Antenna) mission, and external instrument data ingests through the same
pipeline.

**[Manual](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/)** · [Physics](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/physics/) ·
[Configuration](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/usage/) · [Analysis interfaces](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/interfaces/) ·
[Scenario library](scenarios/README.md) · [Changelog](CHANGELOG.md)

> "DSN" denotes throughout a deep-space ground-station network in the generic
> sense; the LISA passes are ESA ESTRACK 35 m antenna passes.

![Mission summary of the stress scenario: seven daily passes against a
growing onboard buffer, an 18 h solar-flare blackout with a 12 h recovery
ramp, a partial ground-station outage, a scheduled generation gap, and an
event marker with its triggered low-latency
period](docs/src/assets/mission_summary.png)

One week of the shipped `scenarios/stress_8h_bursty.toml`: 8 h daily passes
on the physical link, a bursty Gilbert–Elliott channel, an 18 h solar-flare
blackout followed by a 12 h recovery ramp on day 2.5, a 12 h partial
ground-station outage on day 5, a scheduled generation gap on day 1.5, and
an event marker on day 4 whose triggered low-latency period opens six hours
later at half capacity. The onboard buffer doubles from 288 to 581 batches
across the week — the disruption debt the link never recovers — while 707
batches reach the ground and retransmission recovers all 47 rejected
transfers, leaving the lost-batch strip at zero. Every number here comes
from the run recorded in
[`docs/src/assets/PROVENANCE.toml`](docs/src/assets/PROVENANCE.toml).

## Project Structure

```text
DeepSpaceTelemetry/
├── src/            # The library: configuration and I/O, channel models, the
│                   #   instrument, emitter, receiver, metrology, HDF5 export,
│                   #   publication figures, and the mission supervisor
├── scripts/        # Entry points (headless run, dashboard) and post-processing
├── scenarios/      # Eleven complete configurations and their coverage matrix
├── test/           # Static QA, unit, physics, and four integration missions
├── bench/          # BenchmarkTools suites
├── docs/           # Documenter manual sources and the README figures
├── data/runs/      # Ephemeral run directories (gitignored)
├── activate.jl     # Activates and instantiates this environment (one per environment)
├── config.toml     # Default entry point (= scenarios/recovery_12h_seasonal.toml)
└── Project.toml    # Package metadata, deps, compat bounds (+ Manifest.toml)
```

Each auxiliary directory carries its own environment; the run directory's
layout and file contract are specified on the
[analysis interfaces](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/interfaces/) page.

<details>
<summary>Full file tree, annotated</summary>

```text
DeepSpaceTelemetry/
├── src/
│   ├── DeepSpaceTelemetry.jl    # Main module
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
│   ├── Project.toml             # Script environment (terminal UI and logging dependencies; package consumed by path ([sources]))
│   ├── activate.jl              # Activates and instantiates the script environment
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
│   ├── Project.toml             # Test environment (QA deps; package consumed by path ([sources]))
│   ├── activate.jl              # Activates and instantiates the test environment
│   ├── Manifest.toml            # Resolved test environment (committed for portability)
│   └── runtests.jl              # Static QA + unit + physics + 4 integration suites
├── bench/
│   ├── Project.toml             # Benchmark environment (BenchmarkTools; package consumed by path ([sources]))
│   ├── activate.jl              # Activates and instantiates the benchmark environment
│   ├── Manifest.toml            # Resolved benchmark environment
│   └── benchmarks.jl            # Performance benchmarks (incl. channel hot paths)
├── docs/
│   ├── Project.toml             # Docs environment (Documenter; package consumed by path ([sources]))
│   ├── activate.jl              # Activates and instantiates the docs environment
│   ├── Manifest.toml            # Resolved docs environment (committed for portability)
│   ├── make.jl                  # Documenter.jl build script
│   └── src/                     # Manual pages
│       ├── index.md             # Overview, installation, capabilities
│       ├── physics.md           # Noise model, link capacity, channels, queuing, metrology
│       ├── usage.md             # Configuration reference and execution
│       ├── interfaces.md        # Filesystem contract for analysis pipelines
│       ├── api.md               # API reference index
│       └── api/                 # Ten per-module API pages
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
│       ├── .gitkeep             # Keeps the directory in git
│       └── <RUN_ID>/            # onboard/ link/ ground/ lost/ plots/ masks/
│                                # + mission_profile.csv, events_tx.csv, events_rx.csv,
│                                #   component_events.csv, config_snapshot.toml,
│                                #   clock_anchor.toml, emitter.log, receiver.log,
│                                #   heartbeats and RUN_ACTIVE/RUN_COMPLETE/RUN_ABORTED
│                                #   sentinels (interfaces.md documents the full contract)
├── .github/workflows/CI.yml     # Test matrix (Linux 1.12 / 1 / pre, macOS and Windows on 1), formatter, docs build and deployment
├── .github/workflows/CompatHelper.yml # Weekly compat-bound update pull requests
├── .github/workflows/TagBot.yml # Release tags after registry merges (active once registered)
├── .github/dependabot.yml       # Monthly GitHub Actions version updates
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
├── Manifest.toml                # Resolved dependency graph (committed for portability)
├── LICENSE
└── README.md                    # Project documentation
```

</details>

## Obtaining the Package

Requires Julia ≥ 1.12 ([juliaup](https://github.com/JuliaLang/juliaup) is the
recommended installer). Clone the repository:

```bash
git clone https://github.com/PaulGoG/DeepSpaceTelemetry.jl.git
cd DeepSpaceTelemetry.jl
```

To consume the package as a library from another environment instead (it is
not registered in the General registry, so it is added by URL, at a release
tag):

```julia
using Pkg
Pkg.add(url = "https://github.com/PaulGoG/DeepSpaceTelemetry.jl", rev = "v1.1.0")
```

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
automatically and silently, so this step is optional; it only avoids a
first-run delay.

Each environment additionally ships an activation script for interactive
work, which activates it and instantiates its manifest without output:

```bash
julia -i activate.jl           # the package environment
julia -i test/activate.jl      # the test environment (Aqua, JET, StableRNGs, …)
julia -i docs/activate.jl      # Documenter
julia -i bench/activate.jl     # BenchmarkTools
julia -i scripts/activate.jl   # the entry points' environment (terminal UI, logging)
```

Each leaves a REPL with that environment active; from an existing REPL,
`include` the same file. The first instantiation of an environment resolves
and precompiles and is therefore slow, afterwards it is a no-op.

## Usage & Execution

The satellite emitter, the ground receiver, and their supervisor run as three
cooperative tasks. Launch with `--threads=3` so each owns a thread
(`--threads=auto` is equivalent in effect; more threads bring no benefit). On
a single thread the pipeline still runs correctly, but a non-yielding stretch
in one component — compilation warm-up, garbage collection, figure rendering
— pauses the others until it yields; the entry point prints an advisory in
that case.

### Run a mission

Headless, on the default configuration:

```bash
julia --project=. --threads=3 scripts/run_full_sim.jl
```

Any argument ending in `.toml` selects another configuration (relative paths
resolve against the current directory, then the package root, so scenario
files may live outside the repository); any other argument sets the run ID.
Both are optional and order-independent:

```bash
julia --project=. --threads=3 scripts/run_full_sim.jl MY_RUN scenarios/stress_8h_bursty.toml
```

Interactively, with the live viewer and the two log followers in their own
terminal windows:

```bash
julia --project=. --threads=3 scripts/launch_dashboard.jl
```

The mission itself runs in the primary terminal, which shows the supervisor's
banner and stage messages. The receiver's own console status panel is off by
default and enabled with `dashboard.receiver_status_panel = true`.

### Tests, benchmarks, and the manual

```bash
julia --project=. test/runtests.jl      # static QA, unit, physics, integration
julia --project=. bench/benchmarks.jl   # BenchmarkTools, incl. the channel hot paths
julia --project=docs docs/make.jl       # the manual into docs/build/
```

The suite (equivalently `Pkg.test()`) runs the Aqua, ExplicitImports, and JET
checks beside the unit and physics-validation testsets and four end-to-end
integration missions: lossless, retention custodian, deterministic total
loss, and a headless mission through the supervisor. The manual is published
at <https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/>, deployed by the
CI docs job on every version tag. The build of the `main` branch is deployed
alongside it on every push and reachable from the version selector at the top
of any page.

<details>
<summary>Post-processing and maintenance commands</summary>

The post-processing commands read a completed run directory; those taking
`[RUN_ID]` default to the most recent run.

```bash
# Chronological animation of the batch routing (--web: README/manual size)
julia --project=. scripts/postprocessing/generate_gif.jl [--web] [RUN_ID]

# HDF5 export of every product of a run, provenance in the root attributes
julia --project=. scripts/postprocessing/export_hdf5.jl [RUN_ID]

# Figures at the width and format of [post_processing.publication], with a sidecar
julia --project=. scripts/postprocessing/export_publication_figures.jl [RUN_ID]

# Expand one mask-timeline row into a point-wise 0/1 column
julia --project=. scripts/postprocessing/apply_telemetry_mask.jl <RUN_ID> 102400 100 output.csv

# Regenerate the example series for physics.data_source = "external"
julia --project=. scripts/maintenance/generate_example_strain.jl

# Purge previous run directories (lists candidates and asks; --yes skips the prompt)
julia --project=. scripts/maintenance/cleanup.jl
```

In the mask expansion, batches in state `4 = Lost` remain masked: a lost
batch never becomes available on the ground.

</details>

## Component Status

| Component | Role | Status |
|---|---|---|
| `TelemetryCore` | configuration accessors and validation, run layout, batch I/O, event logs, provenance | stable; unit, guardrail, and static-QA coverage |
| `ChannelEffects` | loss channels, disruption timeline, composite link model | stable; validated against the analytic stationary loss rate |
| `VirtualInstrument` | calibrated strain synthesis, Robson–Cornish–Liu noise model, external ingestion | stable; noise model checked against reference values |
| `Emitter` / `Receiver` | spacecraft and ground-station state machines, post-processing products and figures | stable; four end-to-end integration missions in the suite |
| `Metrology` | alert-latency and delivery-delay metrics | stable; synthetic-schedule tests |
| `Export` / `Publication` | HDF5 products, journal-width figure export with provenance | stable; round-trip and export tests |
| `Supervisor` | mission plan, supervised tasks, sentinels, banner | stable; restart and policy tests |
| `PlotTheme` | figure theme and scale-aware styling | stable |
| Scenario library | eleven configurations under `scenarios/` | every file validated and the smoke scenario run by the suite |
| Entry points | `run_full_sim.jl` (argument parsing plus `Supervisor.run_mission`), `launch_dashboard.jl`, `live_viewer.jl`, `follow_log.jl` | `run_full_sim.jl` verified on the shipped scenarios at each release (its library call runs the smoke scenario in the suite); the dashboard, live viewer, and log follower are interactive and verified manually |
| Post-processing wrappers | `apply_telemetry_mask.jl`, `export_hdf5.jl`, `export_publication_figures.jl`, `generate_gif.jl`, `standalone_mask_expander.jl` | thin wrappers over the tested library functions (`Receiver.expand_pointwise_mask`, `Export.export_hdf5`, `Publication.export_publication_figures`); the animation engine of `generate_gif.jl` renders over the tested replay (`Receiver.batch_states`) and the standalone expander is a dependency-light copy, both verified on the shipped scenarios at each release |
| Maintenance utilities | `generate_example_strain.jl`, `cleanup.jl` | `generate_example_strain.jl` verified through `scenarios/external_ingest.toml` at each release; `cleanup.jl` interactive (confirmation prompt), verified manually |

## Configuration

The framework is driven entirely by TOML files, free of hardcoded parameters.
Every key carries its safe interval inline, and `validate_config` enforces it
at startup: a hard error on code-breaking values, a warning on suspicious
ones, before any data is generated. Every run archives the configuration it
used as `config_snapshot.toml`, so provenance never depends on the driving
file's location.

`config.toml` at the package root is the default entry point, a copy of the
reference scenario `scenarios/recovery_12h_seasonal.toml`: 7 mission days at
the seasonal peak on the physical link, a 2-day backlog, Gilbert–Elliott
loss, three disruption events, one marker, about 3 minutes of wall time. Ten
further scenarios ship beside it, from a 12-second smoke run to a 30-day
seasonal mission, covering the physical link rates and the peak-capacity
abstraction, bursty and memoryless channels, the drop policy, explicit pass
schedules, the recorder ceiling, long segments that resolve the
galactic-confusion band, and external ingestion. The
[coverage matrix](scenarios/README.md) states the regime each one produces.

<details>
<summary>Configuration sections</summary>

```toml
[simulation]        # speed_up, mission span, backlog, rng_seed
[storage]           # disk + inode budgets for the run directory, estimator calibration
[retention]         # the retention custodian: grace window, watermark, log rotation
[telemetry]         # daily DSN session window, capacity, bandwidth profile
[contacts]          # seasonal modulation, exceptions, explicit passes, low-latency periods
[physics]           # data source, sample rate, segment/batch geometry
[ground]            # processing budget added to every alert latency
[packet_loss]       # enabled, model (bernoulli | gilbert_elliott), probabilities,
                    # on_loss (retransmit | drop), max_retries
[disruption]        # [[disruption.events]]: start_day, duration_hours, severity,
                    # recovery_hours, loss_multiplier (+ optional affects, type, label)
[events]            # [[events.markers]]: declared event instants
[dashboard]         # auxiliary terminals to spawn, receiver status panel on the console
[post_processing]   # mask matrix, point-wise expansions, HDF5 and publication export
```

`target_event_rows` accepts the string `"all"` (or `["all"]`), integer row
indices (`-1` selects the final row), and `"start:stop"` range strings, mixed
freely — for example `[-1, "10:20", 45]`. The
[configuration reference](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/usage/) documents every key.

</details>

## Capabilities

- **Link and contacts** — the pass profile (`sine`, `sigmoid`, `gaussian`,
  `flat`) or the physical rate pair (`downlink_kbps`,
  `onboard_data_rate_kbps`); seasonal pass-duration modulation, per-date
  exceptions for missed and shortened passes, explicit pass lists in TOML or
  CSV, and low-latency periods at a station-availability capacity fraction.
- **FIFO/LIFO routing** — live data is transmitted immediately with absolute
  priority; the blind-spot backlog is downlinked newest-first, so the data
  most tightly coupled to a live event is recovered first.
- **Loss and disruption** — every transfer attempt draws from a memoryless
  Bernoulli or a bursty two-state Gilbert–Elliott channel, the latter
  validated against its analytic stationary rate. Retransmission is deferred
  by the round-trip light time, blocks the head of the line, and ends after
  `max_retries`, at which point the batch moves to `lost/` rather than being
  deleted. Scheduled disruptions apply a full or partial blackout, a linear
  recovery ramp, and elevated loss; generation gaps stop production instead
  of the link; and the on-board recorder ceiling discards new data at
  capacity, recording the loss as a gap.
- **Payload** — amplitude-calibrated synthetic LISA strain, phase-continuous
  across segments through windowed overlap-add FFT synthesis, reproducing the
  sky-averaged sensitivity of Robson, Cornish & Liu (2019) at the correct
  absolute level with a selectable galactic-confusion fit; or ingestion of an
  external continuous CSV series. Every stochastic draw is seeded from
  `simulation.rng_seed`.
- **Metrology** — the alert-latency curve, giving the time after a live event
  at which the look-back window δ is complete on the ground under the
  realized doctrine against a counterfactual FIFO drain over the same service
  completions; and the measurement-to-ground delivery delay of every batch
  against a requirement (24 h for LISA). Declared event markers are stamped
  into the batch metadata and evaluated by both metrics.
- **Data products** — append-only emitter and receiver event logs, from which
  post-processing replays the exact per-batch state history; the 0–4 mask
  timeline and point-wise 0/1 availability masks; the metrics profile; the
  batch-state raster, which shows the LIFO backfill advancing backwards in
  batch identifier; a Welch estimate of the delivered payload against the
  noise model it was drawn from; an HDF5 export of every product carrying the
  run's provenance as attributes; publication figures at a declared printed
  width with a provenance sidecar; and a chronological animation.
- **Provenance and safety** — every run archives its configuration snapshot,
  platform fingerprint, and git commit; results are written with
  `safesave`-style `#k` backup rotation; and each post-processing product
  runs inside its own guard, so one failure costs neither the others nor the
  completed run data.
- **Monitoring** — a change-driven `UnicodePlots` terminal viewer with live
  disruption and loss status lines, beside size-rotated `.log` files kept
  free of ANSI sequences.

The [manual](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/) documents each of these in full.

## Architecture Summary

Two asynchronous tasks exchange physical batch directories through a
file-system broker, coordinated only by the shared accelerated clock:

1. **Emitter** (`src/Emitter.jl`) — generates strain segments, assembles them
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
waveform backwards in time without temporal gaps.

![Batch-routing animation: one row per stage, sky blue for live batches and
green for archive ones, with the mission clock and the buffer counters in
every frame](docs/src/assets/batch_routing.gif)

The same run, batch by batch. Each row is a stage — buffered on the
satellite, in flight on the link, delivered on the ground — and the color
the routing family: sky blue live (FIFO), green archive (LIFO), the marker
shape repeating the distinction. Live batches cross as they are generated,
so the sky-blue runs mark the passes, and between them the archive segment
grows backwards in batch identifier, contiguous with the live tail. Through
the blackout the ground row stands still while the onboard block extends to
the right. Each frame states the mission clock, the link state, and the
onboard and ground counts.

External analysis pipelines couple to a run exclusively through the
filesystem — batch directories delivered by atomic `mv`, append-only event
feeds, and the mask products — under a read/copy-only contract that admits
any number of concurrent consumers. The
[analysis interfaces](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/interfaces/) page specifies every file and column.

## Citing, contributing, license

Citation metadata is in `CITATION.cff` (Citation File Format 1.2.0), which
GitHub renders as a citation widget and `cffconvert` turns into BibTeX; cite
the version used, by tag. `CONTRIBUTING.md` states the working conventions:
environment activation, the test suite with its static-analysis checks,
formatting, documentation, configuration changes, and the commit and
pull-request format. The package is MIT-licensed — see `LICENSE`.
