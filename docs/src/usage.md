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
### Scenario Library

The repository ships a library of complete configurations under
`scenarios/`, each runnable by path; `scenarios/README.md` carries the
coverage matrix and the expected regime of every file. `config.toml` at the
package root is the default entry point and is a copy of
`scenarios/recovery_12h_seasonal.toml`. Per the configuration-comment
policy, the TOML files carry only per-key descriptions, admissible choices,
and safe intervals — the scenario rationale lives in the library README and
here.

The reference scenario — **recovery at the seasonal peak** (~3 min wall
time, 7 mission days from 21 June 2035) — runs the physical link:
230 kbit/s downlink against 75 kbit/s production, flat within the pass
(the Definition Study Report's sustained rate), with the daily 8-hour
window widened by the 4-hour seasonal extension to 12-hour passes. The
mission opens with a 2-day blind-spot backlog (288 batches at the shipped
physics: 60 s segments, 10 segments per batch → 144 batches/day) served by
12-hour passes of about 190 batches each over a bursty Gilbert–Elliott channel
(sticky BAD state, 50 % loss while BAD). Three scheduled events stress the
mission: a 15-minute antenna repointing on day 1.5 (a generation gap), a
day-2.5 solar-flare-class full blackout (18 h, then a 12 h linear recovery
ramp with 5× elevated loss), and a day-5.0 partial DSN outage (severity
0.8, 12 h, 6 h ramp, 3× loss). An event marker at 14:00 on day 4 triggers,
six hours later, a 3-hour low-latency period at half capacity. The flare
and the outage each cost about one pass, so the week ends with the backlog
near its initial level (the buffer oscillates between 120 and 300 batches)
where the same timeline under 8-hour passes doubles it.

The same disruption timeline under 8-hour January passes is
`scenarios/stress_8h_bursty.toml`, where the link delivers 138 batches per
day against 144 produced and the backlog grows; `scenarios/nominal_8h.toml`
is the balanced case without backlog or disruptions; the pre-library
default — a 60 batches/h peak under a Gaussian profile — is
`scenarios/abstraction_gaussian_peak.toml`. The library also covers a drop
policy, an explicit pass schedule, a 30-day seasonal mission reaching the
recorder ceiling, 2400 s segments that resolve the galactic-confusion band,
and external ingestion. Under the physical rate pair only the flat profile
sustains production: a day's capacity is the link rate times the pass
length times the profile mean (flat 1.0, sine 0.5, Gaussian σ = 0.15 0.38),
so the shaped profiles remain stress abstractions of a partially usable
pass. `validate_config` warns when the rate pair meets a shaped profile,
stating the profile mean and the capacity of one nominal pass against the
daily production (`TelemetryCore.capacity_balance`), and the mission banner
prints the same balance as its `Capacity:` line for every run.

Any CLI argument ending in `.toml` selects the configuration (relative
paths resolve against the current directory, then the package root); any
other argument sets the run ID (both optional, order-independent):
```bash
julia --threads=3 --project=. scripts/run_full_sim.jl MY_RUN scenarios/stress_8h_bursty.toml
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

[[disruption.events]]
type = "antenna_repointing" # affects = "generation" by default for this type
start_day = 1.5
duration_hours = 0.25       # no data produced for 15 min; severity/recovery/loss ignored
```

The on-board recorder is bounded by `[storage] onboard_capacity_days`
(default 14): once the buffer holds that many days of production, new
batches are discarded until room returns (no eviction), and the loss is
recorded as a `RECORDER` gap in the transmit event log.

Reproducibility: `simulation.rng_seed` seeds the physics stream and the loss
channel independently (seed and seed+1). Identical config → identical noise
and identical loss realizations.

### Contact Schedule
`[contacts]` shapes the daily window of `[telemetry]`; every key is optional.
```toml
[contacts]
seasonal_extension_hours = 4.0      # 8 h window at the trough, 12 h at the peak
season_peak_day_of_year = 172.0
low_latency_enabled = true          # set to false for the counterfactual run

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

### Event Markers
`[[events.markers]]` declare the instants the alert-latency metric is
evaluated at; a marker may trigger a low-latency period after a reaction
delay, and `[ground]` holds the processing budget added to every latency.
```toml
[ground]
processing_latency_hours = 1.0

[[events.markers]]
time = "2035-01-05T14:00:00"
label = "transient candidate"
low_latency_after_hours = 6.0       # optional: triggered period, 6 h after the marker
low_latency_duration_hours = 3.0
low_latency_capacity_fraction = 0.5
```

### Synthetic Noise Model
Two optional `[physics]` keys govern the synthetic strain (the model is stated on the physics page):
```toml
[physics]
confusion_observation_years = 1.0   # galactic-confusion fit: 0.5 | 1.0 | 2.0 | 4.0
noise_f_min_hz = 1e-5               # bins below this frequency carry no power
```
The confusion band (0.5–3 mHz) is resolved only for `segment_duration_sec ≳ 2000 s`; at 60 s segments the first resolved bin is 8.3 mHz.

### External Data Ingestion
An external high-frequency CSV time series replaces the synthetic noise with:
```toml
[physics]
data_source = "external"
external_data_path = "path/to/data.csv"
sample_rate = 1024.0
segment_duration_sec = 60.0
batch_size = 15
```
The simulator slices the series into batches, consuming its first portion as the pre-existing blind-spot backlog.

## Running the Simulation
The emitter, the receiver, and the supervisor are three cooperative tasks;
launch with `--threads=3` so each owns a thread (`auto` is equivalent in
effect, more threads bring nothing). On a single thread the run is still
correct — the emitter paces itself on the mission clock and recovers stalls
by catch-up — but a non-yielding stretch in one component (compilation
warm-up, garbage collection, figure rendering) pauses the others until it
yields, and the entry point prints an advisory.

**Interactive Dashboard:**
```bash
julia --project=. --threads=3 scripts/launch_dashboard.jl
```
This spawns the log terminals and the change-driven `UnicodePlots` live viewer (redrawn only on state change).

**Headless Mode:**
```bash
julia --project=. --threads=3 scripts/run_full_sim.jl
```
The receiver's console status panel (a text panel redrawn on every receiver
iteration, which clears the terminal) is off by default;
`dashboard.receiver_status_panel = true` enables it for a headless run whose
terminal shows nothing else.

## Post-Processing & Masks
After a run, the system outputs `masks/telemetry_mask_timeline.csv`. This 2D matrix logs the exact state of every batch (`0=Future`, `1=Onboard`, `2=Link`, `3=Ground`, `4=Lost`) at every telemetry event. The reconstruction is exact: the emitter and receiver append every batch milestone to `events_tx.csv` / `events_rx.csv` (generation, transmission, ingest, retry, loss) and post-processing replays those ground-truth logs. Runs without event logs (pre-0.9 layouts) are not supported by the replay.

Post-processing always reads the run's own `config_snapshot.toml`, so analyzing an old run stays correct after `config.toml` edits.

One matrix row expands into a high-resolution point-wise 0/1 availability array (multiplied against the raw time series, it blanks out undelivered data):
```bash
julia --project=. scripts/postprocessing/apply_telemetry_mask.jl <RUN_ID> <total_points> <event_row_index> <output.csv>
```
`event_row_index = -1` selects the final snapshot. To automate this after every run, set `expand_to_pointwise_masks = true` in `config.toml` and list the rows in `target_event_rows` (accepts `"all"`, integers with `-1` for the last row, and `"start:stop"` range strings).

External collaborators without this repository can use the dependency-light copy `scripts/postprocessing/standalone_mask_expander.jl`, which needs only `CSV` and `DataFrames`.

With `hdf5_export = true` in `[post_processing]` every product — event logs, metrics, masks, metrology tables, markers — is additionally written to `products.h5` with the run's provenance as attributes (layout in the Analysis Interfaces page); the same file can be produced afterwards for any run:
```bash
julia --project=. scripts/postprocessing/export_hdf5.jl [RUN_ID]
```

## Publication Figures
`[post_processing.publication]` re-renders every figure of a run — mission
summary, session figures, alert latency, delivery delay — at a declared
printed width in a vector format, into one directory with a
`PROVENANCE.toml` sidecar (run ID, package version, git commit, snapshot
hash, file list), each file named `<stem>__<run_id>.<format>`:
```toml
[post_processing.publication]
enabled = true
format = "pdf"              # or "svg"
column_width_mm = 86.0      # single column; 178 = the double-column design width
export_dir = "figures_export"     # "" = <run_dir>/publication
```
Text keeps at least 7 pt at the printed size and narrow figures gain
height for the wrapped legends. The same export runs afterwards for any
run with the settings of its snapshot:
```bash
julia --project=. scripts/postprocessing/export_publication_figures.jl [RUN_ID]
```

## GIF Animation
To visualize the LIFO/FIFO routing physics of a completed run:
```bash
julia --project=. scripts/postprocessing/generate_gif.jl [--web] [RUN_ID]
```
Every frame is one row of `mission_profile.csv` — a change-driven cadence,
so the animation is not linear in mission time — and states the mission
clock, the link state, and the buffer counters. Two rendering profiles
exist: the default archive profile (1400 units wide, two raster units each,
at most 800 frames) and `--web`, which writes the size the README and the
manual carry (900 px, at most 240 frames, a few megabytes) as
`telemetry_animation_web.gif`.