# DeepSpaceTelemetry

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/)
[![CI](https://github.com/PaulGoG/DeepSpaceTelemetry.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/PaulGoG/DeepSpaceTelemetry.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/PaulGoG/DeepSpaceTelemetry.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/PaulGoG/DeepSpaceTelemetry.jl)
[![Aqua QA](https://juliatesting.github.io/Aqua.jl/dev/assets/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![JET](https://img.shields.io/badge/tested%20with-JET.jl-233f9a)](https://github.com/aviatesk/JET.jl)
[![Format](https://github.com/PaulGoG/DeepSpaceTelemetry.jl/actions/workflows/Format.yml/badge.svg?branch=main)](https://github.com/PaulGoG/DeepSpaceTelemetry.jl/actions/workflows/Format.yml?query=branch%3Amain)
[![Julia](https://img.shields.io/badge/dynamic/toml?url=https%3A%2F%2Fraw.githubusercontent.com%2FPaulGoG%2FDeepSpaceTelemetry.jl%2Fmain%2FProject.toml&query=%24.compat.julia&label=julia&color=9558b2)](https://julialang.org/downloads/)

A Julia framework simulating the telemetry environment of deep-space science
missions: duty-cycled deep-space-network (DSN) contact windows, prioritized
near-real-time (FIFO) transmission with LIFO archival backfill, stochastic
packet loss with retransmission, and scheduled link disruptions. The
telemetry, channel, and queuing layers are mission-agnostic; the shipped
scenarios model the LISA (Laser Interferometer Space Antenna) mission, and
the same pipeline ingests external instrument data. Missions run on a
wall-paced clock, accelerated or at mission cadence, for rehearsals with live
dashboards, or unpaced on a logical clock; both reproduce a run from its
seed.

**[Manual](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/)** · [Physics](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/physics/) ·
[Configuration](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/usage/) · [Scenario gallery](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/gallery/) ·
[Analysis interfaces](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/interfaces/) · [Scenario library](scenarios/README.md) · [Changelog](CHANGELOG.md)

> "DSN" denotes throughout a deep-space ground-station network in the generic
> sense; the LISA passes are ESA ESTRACK 35 m antenna passes.

## Project structure

```text
DeepSpaceTelemetry/
├── src/            # The main package: mission, metrology, and publication figures
├── headless/       # The simulator without figures: channel models, instrument,
│                   #   emitter, receiver, metrology tables, supervisor, sweeps
├── reader/         # Configuration and I/O (TelemetryCore) and the run adapter
├── deploy/         # Container image and entry point of the headless package
├── scripts/        # Entry points (headless run, dashboard, sweeps) and post-processing
├── scenarios/      # Twelve complete configurations and their coverage matrix
├── test/           # Static QA, unit, physics, and integration missions
├── bench/          # BenchmarkTools suites
├── docs/           # Documenter manual sources, the figures, and their render script
├── data/runs/      # Run directories (gitignored)
├── activate.jl     # Activates and instantiates this environment (one per environment)
├── config.toml     # Default entry point (= scenarios/recovery_12h_seasonal.toml)
└── Project.toml    # Package metadata, deps, compat bounds
```

The [analysis interfaces](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/interfaces/)
page specifies the layout and file contract of a run directory.

![Mission summary of the stress scenario: link capacity, onboard buffer, and
cumulative batches on the ground over one
week](docs/src/assets/gallery/stress_8h_bursty_mission_summary_global.png)

One week of the shipped `scenarios/stress_8h_bursty.toml`: 8 h daily passes
on the physical link, a bursty Gilbert–Elliott channel, an 18 h blackout
after a solar particle event followed by a 12 h recovery ramp on day 2.5,
a 12 h partial ground-station outage on day 5, a scheduled generation gap
on day 1.5, and an event marker on day 4 whose triggered low-latency
period opens six hours later at half capacity. After retransmissions the
link delivers fewer batches per day than the spacecraft produces, and each
disruption adds to the backlog: the onboard buffer grows from 288 to 533
batches over the week, while 756 batches reach the ground. Retransmission
recovers all 49 rejected transfers, and the lost-batch strip stays at zero.
This is a tick-mode run;
[`docs/src/assets/PROVENANCE.toml`](docs/src/assets/PROVENANCE.toml) records
its seed, commit, platform, Julia version, and manifest digest. The
[scenario library](scenarios/README.md#gallery) shows nine further scenarios
through the same figure.

## Installation

Requires Julia ≥ 1.12 ([juliaup](https://github.com/JuliaLang/juliaup) is the
recommended installer). Clone the repository:

```bash
git clone https://github.com/PaulGoG/DeepSpaceTelemetry.jl.git
cd DeepSpaceTelemetry.jl
```

The repository holds three packages that share one version. A consumer
that only reads run directories adds the reader package alone, with
`TelemetryCore` and `RunAdapter`:

```julia
using Pkg
Pkg.add(url = "https://github.com/PaulGoG/DeepSpaceTelemetry.jl", subdir = "reader")
```

A project that depends on the main package adds it by URL. Julia 1.13
resolves the reader and the headless package through the package's own
`[sources]` entries; the Pkg of Julia 1.12 does not follow the `[sources]`
of a dependency, so there the three packages are added in one call:

```julia
using Pkg
url = "https://github.com/PaulGoG/DeepSpaceTelemetry.jl"
Pkg.add([
    Pkg.PackageSpec(; url, subdir = "reader"),
    Pkg.PackageSpec(; url, subdir = "headless"),
    Pkg.PackageSpec(; url),
])
```

A pipeline that runs missions without figures, in a container for
instance, adds the headless package instead, with the reader in the same
call on every Julia version (`subdir = "headless"` and `subdir =
"reader"`). Its dependency closure is MIT-licensed apart from DataStrings
(Apache-2.0); the figure stack of the main package brings GPL-licensed and
non-free binaries. `deploy/Dockerfile` builds a container image of the
headless package, and the
[Headless Package and Containers](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/headless/)
page of the manual covers the licences, the data root, and the image.

The commands below are written for the package root, the cloned repository
directory. The scripts also run from any other working directory: a relative
config path not found there resolves against the package root. With no
configuration argument, a `config.toml` in the working directory takes
precedence over the package default.

Each entry-point script activates and instantiates its own environment,
without output, as its first statement; no `--project` flag is needed. I do
not track manifests: `Project.toml` with its `[compat]` bounds defines each
environment, and each run stores the manifest it resolved as
`manifest_snapshot.toml` in its run directory.

The same activation scripts open an interactive session:

```bash
julia -i activate.jl           # the package environment
julia -i test/activate.jl      # the test environment (Aqua, JET, StableRNGs, …)
julia -i docs/activate.jl      # Documenter
julia -i bench/activate.jl     # BenchmarkTools
julia -i reader/activate.jl    # the reader package alone
julia -i headless/activate.jl  # the headless package alone
julia -i headless/test/activate.jl # its own test environment
julia -i deploy/activate.jl    # the headless runner (the container's entry point)
julia -i scripts/activate.jl   # the entry points' environment (terminal UI, animation)
```

Each leaves a REPL with that environment active; from an existing REPL,
`include` the same file. The first instantiation of an environment resolves
and precompiles it, which is slow; later ones are no-ops.

## Usage and execution

The emitter and the receiver are cooperative tasks of one driver, which the
supervisor runs on one thread. Mission time advances from one component
wakeup to the next, so a run reproduces its event logs and mask products to
the byte for a given seed on a given platform. Wall mode, the default, paces
the wakeups at `simulation.speed_up` mission seconds per wall second for
`mission_wall_seconds`; a host that lags finishes later with the same
content. Tick mode (`simulation.mode = "tick"`, span `mission_days`) runs
unpaced. The two modes write the same record for the same configuration.

### Run a mission

Headless, on the default configuration:

```bash
julia scripts/run_full_sim.jl
```

The arguments are optional and order-independent. One ending in `.toml`
selects another configuration, `--tick` runs the configuration on the tick
clock with its span unchanged, and any other argument sets the run ID:

```bash
julia scripts/run_full_sim.jl MY_RUN scenarios/stress_8h_bursty.toml
julia scripts/run_full_sim.jl --tick MY_RUN scenarios/stress_8h_bursty.toml
```

A sweep runs a configuration on the tick clock once per seed, with optional
overrides, serially or several runs at once on threads. It writes the
realized totals of all runs to `data/sweeps/<PREFIX>/summary.csv` and its
provenance to `sweep.toml` beside it:

```bash
julia scripts/run_sweep.jl scenarios/stress_8h_bursty.toml MY_SWEEP --seeds 1:8 --workers 4 --set packet_loss.p_loss_bad=0.6
```

Without the figure stack, on the headless package, through the entry point
of the container image. The configuration path is required here, and the
run goes to `headless/data/runs/` unless `DEEPSPACETELEMETRY_DATA` names
another data root:

```bash
julia deploy/run_mission.jl scenarios/smoke_1d.toml --tick SMOKE
```

Interactively, with the live viewer and the two log followers in their own
terminal windows. The shipped configurations keep the windows closed: set
`open_live_viewer`, `open_receiver_log` and `open_emitter_log` under
`[dashboard]` to `true` first.

```bash
julia scripts/launch_dashboard.jl
```

The mission itself runs in the primary terminal, which shows the supervisor's
banner and stage messages. The receiver's own console status panel is off by
default and enabled with `dashboard.receiver_status_panel = true`.

### Tests, benchmarks, and the manual

```bash
julia test/runtests.jl      # static QA, unit, physics, integration
julia bench/benchmarks.jl   # BenchmarkTools, incl. the channel hot paths
julia docs/make.jl          # the manual into docs/build/
```

The suite (equivalently `Pkg.test()`) takes about five minutes: static QA
(Aqua, ExplicitImports, JET), the unit and physics-validation testsets,
end-to-end missions, and three tick missions that check reproducibility.
Setting `DEEPSPACETELEMETRY_TEST_INSTALLED=true` adds a run from a copy that
Pkg installs into a temporary depot, pinned by commit as a downstream
consumer pins it; the copy precompiles from scratch, which adds several
minutes.

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

</details>

## Component status

Every component is stable. The last column names what verifies it.

| Component | Role | Verification |
|---|---|---|
| `TelemetryCore` | configuration accessors and validation, run layout, batch I/O, event logs, provenance, the tick clock and its driver, paced or not | unit, guardrail, scheduler, and static-QA coverage |
| `ChannelEffects` | loss channels, disruption timeline, composite link model, transfer integral | the analytic stationary loss rate; transfer completions against closed forms |
| `VirtualInstrument` | binary flag payload declared by the event markers, external ingestion | flag rule, boundary cases, clock advance, and the payload grid across gaps and restarts |
| `Emitter` / `Receiver` | spacecraft and ground-station state machines on the tick driver | end-to-end integration missions and the tick missions |
| `Masks` / `MissionFigures` | batch-state replay, mask products, the gap table; mission, session, and raster figures | replay, gap-table, legend, and layout tests |
| `Metrology` / `MetrologyFigures` | alert-latency (complete-case and Kaplan–Meier) and delivery-delay tables; their figures | synthetic-schedule tests with hand-derived latencies, Kaplan–Meier quantiles by hand |
| `Export` / `Publication` | HDF5 products (an extension of the headless package, loaded with HDF5), journal-width figure export with provenance | round-trip and export tests |
| `DeepSpaceTelemetryHeadless` | the simulator without the figure stack, for pipelines and containers | its own suite: the licences of the dependency closure, no figure backend, a mission without figures; the image is built with Podman before a release |
| `Supervisor` | mission plan, supervised component tasks, failure policy, sentinels, banner | restart, policy, and reproducibility tests |
| `RunAdapter` | reference run adapter over the file contract: geometry, batches, payload, arrivals, state, labeled intervals; byte-offset feed cursors, hole-feed reader, delivered rows, marker rows, producer-version check | a lossy tick run with a generation gap, checked against the gap table |
| `Sweeps` | ensembles and parameter sweeps on the tick clock, serial or several runs at once on threads, with a summary table and provenance | a two-seed sweep, serial and concurrent, with identical tables |
| `PlotTheme` | figure theme and scale-aware styling | layout-helper tests |
| Scenario library | twelve configurations under `scenarios/` | every file validated and the smoke scenario run end to end; a shortened deterministic scenario run three times |
| Entry points | `run_full_sim.jl` and `deploy/run_mission.jl` (argument parsing, `--tick`, plus `Supervisor.run_mission`), `run_sweep.jl` (`Sweeps.run_sweep`), `launch_dashboard.jl`, `live_viewer.jl`, `follow_log.jl` | the library calls in the suite; `run_full_sim.jl` on the shipped scenarios before a release and `deploy/run_mission.jl` on the smoke scenario in CI; the dashboard, live viewer, and log follower by hand |
| Post-processing wrappers | `complete_run.jl`, `export_hdf5.jl`, `export_publication_figures.jl`, `generate_gif.jl` | thin wrappers over tested library functions (`Supervisor.complete_run`, `Export.export_hdf5`, `Publication.export_publication_figures`); `generate_gif.jl`, over the tested `Masks.batch_states` replay, on the shipped scenarios before a release |
| Maintenance utilities | `generate_example_strain.jl`, `cleanup.jl`, `docs/render_assets.jl` | `generate_example_strain.jl` through `scenarios/external_ingest.toml`; `cleanup.jl` by hand; `render_assets.jl` at every figure regeneration |

<details>
<summary>Full file tree, annotated</summary>

```text
DeepSpaceTelemetry/
├── src/
│   ├── DeepSpaceTelemetry.jl    # Main module; re-exports the headless and reader modules
│   ├── PlotTheme.jl             # CairoMakie theme and styling
│   ├── MissionFigures.jl        # Mission summary, session figures, batch-state raster
│   ├── MetrologyFigures.jl      # Alert-latency and delivery-delay figures
│   └── Publication.jl           # Publication figure export at a declared printed width
├── headless/                    # DeepSpaceTelemetryHeadless, versioned with this package
│   ├── Project.toml             # Headless package: the reader, CSV, DataFrames, logging, stdlib; HDF5 weak
│   ├── activate.jl              # Activates and instantiates the headless environment
│   ├── src/
│   │   ├── DeepSpaceTelemetryHeadless.jl # Module header; exports the modules below
│   │   ├── ChannelEffects.jl    # Packet-loss channels, disruption timeline, LinkModel, transfer completion
│   │   ├── VirtualInstrument.jl # Payload: binary flag series or external CSV ingestion
│   │   ├── Emitter.jl           # Satellite state machine (payload/queues)
│   │   ├── Receiver.jl          # DSN ground station loop, loss handling, retention
│   │   ├── Masks.jl             # Batch-state replay, mask timeline, gap table
│   │   ├── Metrology.jl         # Alert latency (LIFO vs FIFO drain, Kaplan–Meier), delivery delay
│   │   ├── Export.jl            # HDF5 product export through the extension below
│   │   ├── Supervisor.jl        # Mission orchestration: plan, supervised tasks, sentinels
│   │   └── Sweeps.jl            # Ensembles and sweeps on the tick clock
│   ├── ext/DeepSpaceTelemetryHeadlessHDF5Ext.jl # products.h5 with provenance attributes
│   └── test/                    # Licence check of the dependency closure, a mission without figures
├── deploy/
│   ├── Project.toml             # Runner environment: the headless package and the reader by path
│   ├── activate.jl              # Activates and instantiates the runner environment
│   ├── run_mission.jl           # Container entry point (<config.toml> [RUN_ID] [--tick])
│   └── Dockerfile               # Image of the headless package, non-root, data root /data
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
│   ├── Project.toml             # Script environment: terminal UI and animation; package by path via [sources]
│   ├── activate.jl              # Activates and instantiates the script environment
│   ├── launch_dashboard.jl      # Interactive entry point (live viewer + log terminals)
│   ├── run_full_sim.jl          # Headless entry point ([run_id] [config.toml] [--tick]) → Supervisor.run_mission
│   ├── run_sweep.jl             # Sweep entry point (<config> <PREFIX> --seeds --workers --set) → Sweeps.run_sweep
│   ├── live_viewer.jl           # Terminal UI entry point, separate process
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
│       ├── upgrading.md         # Support policy and the changes from 2.x and 3.2
│       ├── headless.md          # Headless package, licences, data root, container image
│       ├── api.md               # API reference index
│       ├── api/                 # Fifteen per-module API pages
│       └── assets/              # gallery/ (figures of the manual and the README) and PROVENANCE.toml
├── scenarios/
│   ├── README.md                # Coverage matrix, expected regime, and the mission summaries of ten scenarios
│   ├── smoke_1d.toml            # 12 s smoke run (suite end-to-end)
│   ├── nominal_8h.toml          # Balanced nominal operations
│   ├── stress_8h_bursty.toml    # 8 h passes without the seasonal term, bursty loss, disruptions: backlog growth
│   ├── recovery_12h_seasonal.toml # Reference scenario (= config.toml): seasonal-peak recovery
│   ├── abstraction_gaussian_peak.toml # Peak-capacity abstraction: 60 batches/h peak, Gaussian profile
│   ├── backlog_recovery_sine.toml # Backlog recovery under retransmission load: 3-day backlog, 10 % loss
│   ├── drop_policy.toml         # 20 % loss without retransmission
│   ├── explicit_schedule.toml   # Explicit pass list with missed, shortened, extended passes
│   ├── long_30d_seasonal.toml   # 30 days, contact gap reaching the recorder ceiling
│   ├── long_segments_2400s.toml # 2400 s segments: the coarse-batch regime
│   ├── external_ingest.toml     # External CSV ingestion
│   └── deterministic_1d.toml    # One mission day on the tick clock
├── data/
│   ├── example_external_strain.csv # Generated demo input (gitignored)
│   ├── runs/                    # Run directories (gitignored)
│   │   ├── .gitkeep             # Keeps the directory in git
│   │   └── <RUN_ID>/            # Run products; the analysis interfaces page documents the contract
│   └── sweeps/<PREFIX>/         # Sweep summary.csv and sweep.toml (gitignored)
├── .github/workflows/CI.yml     # Test matrix (Linux min / 1 / pre, macOS and Windows on 1), headless suite (min / 1), docs
├── .github/workflows/Format.yml # Formatter check on every push and pull request
├── .github/dependabot.yml       # Weekly Julia and GitHub Actions version updates
├── .github/ISSUE_TEMPLATE/      # Bug-report and feature-request forms
├── .github/PULL_REQUEST_TEMPLATE.md # Change, verification, open points
├── activate.jl                  # Activates and instantiates the package environment
├── .dockerignore                # Build context of deploy/Dockerfile: reader/, headless/, deploy/
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

A run is configured by one TOML file. `config.toml` at the package root is
the default entry point, a copy of the reference scenario
`scenarios/recovery_12h_seasonal.toml` (7 mission days at the seasonal peak,
about 3 minutes of wall time); the [scenario library](scenarios/README.md)
documents the eleven others. Each key carries its safe interval in an inline
comment, `validate_config` enforces the intervals before any data is
generated, and a run archives its configuration as `config_snapshot.toml`.

Units are SI, with hours and days for durations, kbit/s for data rates, GiB
and MiB for storage budgets, mm for printed widths and 10⁶ km for the
range; each key states its unit in its name or its comment. Timestamps are
ISO-8601 instants on the mission timeline without a time-scale attribution
(the manual's Physics page).

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
[labels]            # [[labels]]: labeled spans of payload rows
[dashboard]         # auxiliary terminals to spawn, receiver status panel on the console
[post_processing]   # mask matrix, metric and figure flags,
                    # session-figure switch and cap, HDF5 and publication export
```

`validate_config` rejects a 2.x configuration that carries a key removed in
3.0, naming the key and its remedy; the manual's Upgrading and Support page
lists the changes. The
[configuration reference](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/usage/)
documents every key.

</details>

## Capabilities

- Contacts and link: daily passes with a seasonal term, per-date exceptions
  or an explicit pass list, and low-latency periods; four pass profiles on a
  physical rate pair or on a peak capacity.
- Routing and loss: live data first with non-preemptive priority, the
  backlog newest first; a Bernoulli or Gilbert–Elliott channel per transfer,
  retransmission after the round-trip light time, scheduled blackouts,
  generation gaps, and an on-board recorder ceiling.
- Payload and metrology: a declared binary flag series or an external CSV
  series; the alert latency against a counterfactual FIFO drain, and the
  delivery delay against a requirement (24 h for LISA).
- Products and provenance: event logs, the batch-state timeline, the gap
  and label tables, figures, optional HDF5 and publication exports; each
  run archives its configuration, manifest, platform, and source identity.
- Consumers: a run adapter over the file contract, seed sweeps on the tick
  clock, and a terminal viewer for wall-paced rehearsals.

The [manual](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/) lists
them in full.

## Architecture summary

Two tasks exchange batch directories through the file system, coordinated
only by the shared mission clock:

1. The **emitter** (`headless/src/Emitter.jl`) generates payload segments,
   assembles them into batches under `onboard/`, stamps them `LIVE_`
   (generated during a pass) or `ARCH_` (generated in a blind spot or a
   blackout), and moves them to `link/` while the link is up and fewer than
   `max_inflight_batches` are in flight.
2. The **receiver** (`headless/src/Receiver.jl`) serves the batches on
   `link/` one at a time. A transfer lasts until the link capacity
   integrated from its start reaches one batch, so a transfer cut by the end
   of a pass or by a blackout resumes at the next contact. Each attempt
   draws one loss realization at its completion: the batch moves to
   `ground/`, waits on the link for its retransmission, or, once its
   retries are exhausted, moves to `lost/`. Leaving `link/` frees its
   in-flight slot.

The routing order is a design choice of this package: **live data is
transmitted FIFO with non-preemptive priority; residual bandwidth backfills
the archive LIFO (newest first)**, so alert pipelines can extend a live
event's waveform backward in time without gaps. The LISA Definition Study
Report ([doi:10.48550/arXiv.2402.07571](https://doi.org/10.48550/arXiv.2402.07571))
states a 24-hour delivery requirement and low-latency periods, and no
downlink order.

![Batch-routing animation: one row per stage, sky blue for live batches and
green for archive ones, with the mission clock and the buffer counters in
every frame](docs/src/assets/gallery/stress_8h_bursty_telemetry_animation_web.gif)

The same run, batch by batch; the
[physics page](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/physics/)
reads the animation frame by frame.

Analysis pipelines couple to a run only through the filesystem. The
[analysis interfaces](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/interfaces/)
page specifies every file and column, with a worked reader for a streaming
and for a stationary consumer.

## Public surface and versioning

Semantic versioning covers the run-directory file contract, the
configuration schema, the entry-point scripts, and the public names of
`RunAdapter` (Design Principles on the
[analysis interfaces](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/interfaces/)
page); the other modules are implementation and may change between minor
releases. Since 3.0 the package is in maintenance; the
[Upgrading and Support](https://PaulGoG.github.io/DeepSpaceTelemetry.jl/stable/upgrading/)
page states the policy, the supported Julia versions, and the changes from
2.x.

## How to cite

Citation metadata is in `CITATION.cff`, which GitHub renders as a citation
widget. Cite the version used, by tag:

```bibtex
@software{DeepSpaceTelemetry,
  author  = {Gogîță, Paul-Adrian},
  title   = {DeepSpaceTelemetry.jl: a telemetry, channel, and queuing simulator for deep-space science missions},
  year    = {2026},
  version = {3.3.1},
  url     = {https://github.com/PaulGoG/DeepSpaceTelemetry.jl}
}
```

## Contributing, license

`CONTRIBUTING.md` states the working conventions, from environment
activation and the test suite to the commit and pull-request format. The
package is MIT-licensed; see `LICENSE`.
