# DeepSpaceTelemetry

A Julia framework that simulates the telemetry environment of deep-space science missions: contact windows, link physics, queuing, loss, and disruption. The shipped scenarios, a library under `scenarios/`, model the **LISA (Laser Interferometer Space Antenna)** mission. Missions run on a wall-paced clock for rehearsals with live dashboards, or on a logical clock whose runs reproduce to the byte for a given seed.

## Overview
Deep-space missions communicate on asymmetric duty cycles: a daily ground-station contact window followed by a long blind spot in which science data accumulates onboard. The shipped configuration models LISA, which orbits the Sun 50 million kilometers behind Earth, with an 8-hour DSN window against a 16-hour blind spot (12 h passes near the seasonal peak in the default configuration); its payload is a binary flag series marking the segments that hold declared events. The telemetry, channel, and queuing layers remain mission-agnostic. "DSN" denotes throughout a deep-space ground-station network in the generic sense; the LISA passes are ESA ESTRACK 35 m antenna passes.

![Mission summary of the stress scenario](assets/gallery/stress_8h_bursty_mission_summary_global.png)

One week of `scenarios/stress_8h_bursty.toml`: 8 h daily passes on the
physical link, a bursty Gilbert–Elliott channel, an 18 h solar-flare blackout
with a 12 h recovery ramp on day 2.5, a partial ground-station outage on day
5, and a scheduled generation gap on day 1.5. The onboard buffer grows from
288 to 530 batches over the week, and retransmission recovers every rejected
transfer. The [Scenario Gallery](@ref) shows this run through its other
products, nine further scenarios through their own, and the totals of all ten.

## Installation

Requires Julia ≥ 1.12. The package is not registered in the General
registry and is used from a clone of the repository, which carries the
scripts, the scenario library, and the benchmarks. Runs are written under
the data root, `data/runs/` of the clone by default; a copy installed by
Pkg writes under its own directory unless the caller passes `data_root` to
`Supervisor.run_mission` or redirects the default,
`TelemetryCore.DATA_ROOT[]`:

```bash
git clone https://github.com/PaulGoG/DeepSpaceTelemetry.jl.git
cd DeepSpaceTelemetry.jl
```

## Capabilities
* **Payload**: a binary flag series marking the segments that hold a declared event (`0` noise only, `1` flagged signal), or ingestion of an external continuous CSV time series, one or several of its columns as one payload.
* **Link capacity**: either the batches-per-hour abstraction or the physical rate pair `downlink_kbps` / `onboard_data_rate_kbps`, with the catch-up ratio and the capacity of one nominal pass against the daily production reported at start-up.
* **Pass profiles**: `sine`, `sigmoid`, `gaussian`, or `flat` capacity over the pass; the validator states the profile mean when a shaped profile meets a physical rate.
* **Contact schedule**: seasonal pass-duration modulation, per-date exceptions, explicit pass lists (TOML or CSV), and low-latency periods at a station-availability capacity fraction.
* **FIFO/LIFO routing**: live transmission first (FIFO), then the archive backfill in strict LIFO order, so alert pipelines extend a live event's waveform backward in time without gaps.
* **Stochastic packet loss**: per-transfer loss from a memoryless Bernoulli or a bursty Gilbert–Elliott channel, a retransmit/drop policy, and retransmissions deferred by the round-trip light time of the configured range; retry-exhausted batches land in `lost/` (data preserved, mask state `4`).
* **Disruption events**: scheduled link disruptions (full or partial blackout, linear recovery ramp, elevated loss) and scheduled generation gaps such as antenna repointing; the on-board recorder ceiling discards data at capacity and records the loss as a gap.
* **Event markers**: declared instants stamped into the batch metadata and the transmit log; the alert-latency metric is evaluated at each marker, with an optional triggered low-latency period.
* **Two clocks**: one driver advances mission time from one component wakeup to the next on one thread; wall mode paces it against the wall clock at `speed_up`, with heartbeats, restart-on-death, and the live dashboards, tick mode (`simulation.mode = "tick"`, or `--tick` on any scenario) runs it unpaced, and both give the same record for the same configuration (Mission Clocks in the physics page).
* **Post-processing products**: the exact batch-state history replayed from the event logs (`telemetry_mask_timeline.csv`), point-wise 0/1 availability masks (deprecated since 2.11.0; the adapter returns the delivered rows instead), the gap table of every hole in the delivered record with its cause (`masks/gaps.csv`), metrology tables, mission and session figures, an HDF5 export of every product with provenance attributes, and a publication export at a declared printed width with a provenance sidecar.
* **Scenario library**: twelve complete configurations under `scenarios/`, from a half-day smoke run to a 30-day seasonal mission, among them one mission day on the tick clock, each validated by the test suite.
* **Validated configuration**: every tunable has a documented safe interval. At start-up `validate_config` rejects code-breaking values and retired keys with a precise `[CONFIG]` message and warns on suspicious ones. `simulation.rng_seed` seeds the packet-loss channel, the only random stream.
