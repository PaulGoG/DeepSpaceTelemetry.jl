# Usage & Configuration

## The Configuration File (`config.toml`)
The simulator is entirely controlled via a TOML config. Every key's **safe
interval** is documented inline in `config.toml`; `validate_config` enforces
them at startup — code-breaking values abort with a precise message, suspicious
ones warn. Type mismatches (quoted numbers, float counts) and malformed TOML
abort with clean `[CONFIG]` errors; a corrupt run snapshot falls back to the
project config with a warning, so post-processing of an old run is never aborted by it.

Storage is governed up front: `check_storage_limits` prints a per-artifact
estimate (payload, metadata, event logs, metrics, masks, plots, logs, file
count — everything is config-derivable) and enforces the `[storage]` budgets
with mitigation awareness. With `[retention]` disabled, a projected overrun
**aborts** before any directory is created; with the retention custodian
enabled, the run proceeds (with a warning) as long as the steady-state
footprint — non-prunable classes plus delivered payload capped at
`high_watermark_gb` — fits the budget. The custodian prunes only delivered
`ground/<batch>/seg_*.csv` payload copies, oldest-ingested first, never
within `grace_hours` of mission time, and records every pruning as a
`pruned` event; event logs, metrics, masks, snapshots, and `lost/` are never
pruned. Log files rotate at `log_rotate_mb` regardless of `enabled`.
### Shipped Scenario

Exactly one configuration ships with the repository. Per the
configuration-comment policy, the TOML file carries only per-key descriptions,
admissible choices, and safe intervals — the scenario rationale lives here.

`config.toml` — **"complex disruption & bursty loss"** scenario (~3 min wall
time, 7.0 mission days). The mission opens with a 2-day blind-spot backlog
(288 batches at the shipped physics rates: 60 s segments, 10 segments per
batch → 144 batches/day) draining against a Gaussian pass profile with peak
capacity 60 batches/h. The downlink runs over a bursty Gilbert–Elliott
channel (sticky BAD state, 50 % loss while BAD) throughout, and two
scheduled disruption events stress the link: a day-2.5 solar-flare-class
full blackout (18 h, then a 12 h linear recovery ramp with 5× elevated
loss) and a day-5.0 partial DSN outage (severity 0.8, 12 h, 6 h ramp,
3× loss), leaving a 1.25-day nominal tail after the second recovery
completes on day 5.75. A 3-hour low-latency period at half capacity on the
evening of day 4 (mission time 2035-01-05 20:00) drains part of the flare
backlog between the day-4 and day-5 passes.

Alternative scenario configurations (e.g. multi-week recovery studies or
lossless baselines) are maintained outside the repository and passed by
path: any CLI argument ending in `.toml` selects the config (relative paths
resolve against the current directory, then the package root); any other
argument sets the run ID (both optional, order-independent):
```bash
julia --project=. scripts/run_full_sim.jl MY_RUN path/to/scenario.toml
```
Every run archives the exact configuration it used as its own
`config_snapshot.toml`, so reproducibility never depends on the driving
file's location.

### Packet Loss & Disruptions
```toml
[packet_loss]
enabled = true
model = "gilbert_elliott"   # or "bernoulli" (then set p_loss)
p_good_to_bad = 0.02
p_bad_to_good = 0.30
p_loss_good = 0.005
p_loss_bad = 0.40
on_loss = "retransmit"      # or "drop" (= lose on first failure)
max_retries = 3

[[disruption.events]]
type = "link_disruption"    # free string
label = "solar flare"       # optional display name on the dashboard status line
start_day = 10.0            # mission days after start_sim_time
duration_hours = 60.0       # full-blackout phase
severity = 1.0              # 1.0 = zero capacity; 0.4 = 60% capacity retained
recovery_hours = 12.0       # linear ramp back to nominal
loss_multiplier = 8.0       # stochastic loss × 8 during blackout + ramp
```

Reproducibility: `simulation.rng_seed` seeds the physics stream and the loss
channel independently (seed and seed+1). Identical config → identical noise
and identical loss realizations.

### Contact Schedule
`[contacts]` shapes the daily window of `[telemetry]`; every key is optional.
```toml
[contacts]
seasonal_extension_hours = 4.0      # 8 h window at the trough, 12 h at the peak
season_peak_day_of_year = 172.0
low_latency_enabled = true          # flip to false for the counterfactual run

[[contacts.exceptions]]             # the window of one date, verbatim
date = "2035-01-04"
duration_hours = 0.0                # 0 = missed pass; omit start to keep session_start

[[contacts.low_latency_periods]]
start = "2035-01-05T20:00:00"
duration_hours = 3.0
capacity_fraction = 0.5             # station availability as a fraction of peak
label = "transient follow-up"
```
A planned pass list replaces the daily generator (exceptions are then not
admissible), either inline
```toml
[[contacts.passes]]
start = "2035-01-02T08:00:00"
duration_hours = 6.0
```
or as `schedule_csv = "path/to/passes.csv"` with the columns
`Start, DurationHours` (relative paths resolve against the current directory,
then the package root). Passes may cross midnight and must not overlap.

### External Data Ingestion
To use your own high-frequency CSV time series instead of synthetic noise:
```toml
[physics]
data_source = "external"
external_data_path = "path/to/your/data.csv"
sample_rate = 1024.0
segment_duration_sec = 60.0
batch_size = 15
```
The simulator will automatically slice your data into batches, consuming the first portion to simulate the pre-existing blind spot.

## Running the Simulation
The emitter, the receiver, and the supervisor are three cooperative tasks;
launch with `--threads=3` so each owns a thread (`auto` is equivalent in
effect, more threads bring nothing). On a single thread the run is still
correct — the emitter paces itself on the mission clock and recovers stalls
by catch-up — but a non-yielding stretch in one component (compilation
warm-up, garbage collection, figure rendering) pauses the others until it
yields, and the entry point prints an advisory.

**Interactive Dashboard (Mission Control):**
```bash
julia --project=. --threads=3 scripts/launch_dashboard.jl
```
This spawns real-time logs and a flicker-free `UnicodePlots` Live Viewer.

**Headless Mode:**
```bash
julia --project=. --threads=3 scripts/run_full_sim.jl
```

## Post-Processing & Masks
After a run, the system outputs `masks/telemetry_mask_timeline.csv`. This 2D matrix logs the exact state of every batch (`0=Future`, `1=Onboard`, `2=Link`, `3=Ground`, `4=Lost`) at every telemetry event. The reconstruction is exact: the emitter and receiver append every batch milestone to `events_tx.csv` / `events_rx.csv` (generation, transmission, ingest, retry, loss) and post-processing replays those ground-truth logs. Runs without event logs (pre-0.9 layouts) are not supported by the replay.

Post-processing always reads the run's own `config_snapshot.toml`, so analyzing an old run stays correct after `config.toml` edits.

To expand one matrix row into a high-resolution point-wise 0/1 availability array (multiply it against your raw time series to blank out undelivered data):
```bash
julia --project=. scripts/postprocessing/apply_telemetry_mask.jl [RUN_ID] <total_points> <event_row_index> <output.csv>
```
`event_row_index = -1` selects the final snapshot. To automate this after every run, set `expand_to_pointwise_masks = true` in `config.toml` and list the rows in `target_event_rows` (accepts `"all"`, integers with `-1` for the last row, and `"start:stop"` range strings).

External collaborators without this repository can use the dependency-light copy `scripts/postprocessing/standalone_mask_expander.jl`, which needs only `CSV` and `DataFrames`.

## GIF Animation
To visualize the LIFO/FIFO routing physics of a completed run:
```bash
julia --project=. scripts/postprocessing/generate_gif.jl [RUN_ID]
```