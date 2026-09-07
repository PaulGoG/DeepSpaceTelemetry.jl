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
shipped scenario and the synthetic physics payload model the LISA (Laser
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
│   └── src/                     # Manual pages (index, physics, usage, interfaces, api)
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
├── .gitignore                   # Excludes run data and generated artifacts
├── .JuliaFormatter.toml         # Committed formatter configuration
├── CHANGELOG.md                 # Notable changes (Keep a Changelog format)
├── config.toml                  # The shipped config — safe intervals documented per key
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
reference) into `docs/build/`.

---

## Configuration

The framework is driven entirely by TOML files, free of hardcoded parameters.
**Safe parameter intervals are documented inline, key by key, in
`config.toml`** and enforced at startup by `validate_config` (hard `error`
for code-breaking values, `@warn` for suspicious ones). Exactly one
configuration ships with the repository — `config.toml`, the "complex
disruption & bursty loss" scenario (7.0 mission days, 2-day launch backlog,
Gilbert–Elliott bursty loss, two scheduled disruption events, ~3 min wall
time; rationale in `docs/src/usage.md` §Shipped Scenario). Alternative
scenario configs are kept outside the repository and passed by path on the
CLI; each run archives the exact configuration it used as
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
    the one-sided LISA PSD at the correct absolute level — or ingests external
    continuous CSV time series without gaps or duplication across the
    pre-population boundary. All stochastic draws are seeded from
    `simulation.rng_seed`.
*   **Dynamic bandwidth profiling**: models the horizon-to-horizon satellite
    pass using `sine`, `sigmoid`, `gaussian`, or `flat` capacity profiles.
*   **Alert-latency metrology** (`Metrology.jl`): from the event logs, how
    long after a live event the data at look-back `δ` reach the ground —
    realized live-FIFO/archive-LIFO doctrine against a counterfactual FIFO
    drain over the same service completions (`alert_latency.csv`, figure).
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

## License

MIT — see `LICENSE`.
