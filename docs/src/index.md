# DeepSpaceTelemetry

A Julia framework simulating the telemetry environment of deep-space science missions — contact windows, link physics, queuing, loss, and disruption — with the **LISA (Laser Interferometer Space Antenna)** mission as the shipped scenarios (a library under `scenarios/`).

## Overview
Deep-space missions communicate on asymmetric duty cycles: a daily ground-station contact window followed by a long blind spot in which science data accumulates onboard. This framework simulates the physics, link constraints, and queuing logic of that regime end to end. The shipped configuration models LISA — orbiting the Sun 50 million kilometers behind Earth, with an 8-hour DSN window against a 16-hour blind spot, and amplitude-calibrated gravitational-wave strain as the payload — while the telemetry, channel, and queuing layers remain mission-agnostic.

## Installation

Requires Julia ≥ 1.12. The package is not yet registered; add it by URL, or
clone the repository for the full pipeline workflow (scripts, shipped
scenario, benchmarks):

```julia
using Pkg
Pkg.add(url = "https://github.com/PaulGoG/DeepSpaceTelemetry.jl")
```

## Capabilities
* **Continuous Physics Engine**: Natively generates amplitude-calibrated, phase-continuous synthetic LISA strain, or ingests external continuous CSV time-series arrays.
* **Dynamic Bandwidth**: Models the horizon-to-horizon satellite pass using `sine`, `sigmoid`, `gaussian`, or `flat` curves.
* **FIFO/LIFO Routing**: Prioritizes live transmission (FIFO) while backfilling the archive in strict LIFO order, so alert pipelines can extend a live event's waveform backwards in time without gaps.
* **Stochastic Packet Loss**: Per-transfer downlink loss drawn from a configurable channel model — memoryless Bernoulli or bursty two-state Gilbert–Elliott — with a retransmit/drop retry policy; retry-exhausted batches land in `lost/` (data preserved) and appear as mask state `4`.
* **Disruption Events**: Scheduled link disruptions (solar flares, safe-mode entries, ground-station outages) declared in the config: full or partial blackout, a linear recovery ramp, and elevated loss rates while the event is active. Onboard backlog accumulation and post-event drain emerge from the same queuing mechanics as the daily blind spots.
* **Automated Post-Processing**: Tracks the exact state of every batch across time (the 2D `telemetry_mask_timeline.csv` matrix, reconstructed exactly from ground-truth event logs) and provides utilities to expand it into point-wise 0/1 ground-availability masks for external datasets.
* **Validated Configuration**: Every tunable has a documented safe interval; `validate_config` aborts on code-breaking values and warns on suspicious ones before a single byte is generated. All RNGs are seeded from the config for full reproducibility.

Navigate the manual using the sidebar: the physics engine, usage and configuration, the filesystem analysis interfaces, and the full API reference.