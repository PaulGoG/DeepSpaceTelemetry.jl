# Usage & Configuration

## The Configuration File (`config.toml`)
Mission parameters are set in a TOML file, and `config.toml` documents the
**safe interval** of each key inline. `validate_config` enforces them at
startup: code-breaking values abort with a precise message, suspicious ones
warn. Type mismatches (quoted numbers, float counts) and malformed TOML
abort with a `[CONFIG]` message rather than a stack trace.

The keys the sections below do not discuss, with the value that applies when
a key is absent:

| Key | Default | Admissible |
|---|---|---|
| `simulation.initial_downtime_days` | 0 | ≥ 0 [d] |
| `simulation.rng_seed` | 0 | integer |
| `storage.max_storage_gb`, `max_ram_gb` | 5, 8 | > 0 [GiB] |
| `storage.max_file_count` | 1 000 000 | integer > 0 |
| `retention.grace_hours`, `log_rotate_mb` | 24, 64 | > 0 [h], [MiB] |
| `retention.high_watermark_gb` | 0.75 × `max_storage_gb` | (0, `max_storage_gb`] [GiB] |
| `telemetry.session_start`, `session_duration_hours` | required | `HH:MM:SS`; (0, 24] [h] |
| `telemetry.downlink_kbps`, `onboard_data_rate_kbps` | required without `max_batches_per_hour` | > 0 [kbit/s], both or neither |
| `telemetry.max_batches_per_hour` | required without the rate pair | > 0; excludes the rate pair |
| `telemetry.bandwidth_profile` | `"sine"` | `"sine"`, `"sigmoid"`, `"gaussian"`, `"flat"` |
| `telemetry.sigmoid_steepness`, `gaussian_sigma` | 10, 0.15 | > 0 |
| `telemetry.max_inflight_batches` | 5 | integer ≥ 1 |
| `telemetry.min_link_factor` | 0.05 | [0, 1) |
| `telemetry.range_million_km` | 0 (no light-time delay) | ≥ 0 [10⁶ km] |
| `contacts.season_period_days` | 365.25 | > 0 [d] |
| `contacts.season_peak_day_of_year` | 172 | [1, 366] |
| `contacts.low_latency_capacity_fraction` | 1 | (0, 1] |
| `packet_loss.enabled`, `model`, `p_loss` | false, `"bernoulli"`, 0.05 | boolean; `"bernoulli"`, `"gilbert_elliott"`; [0, 1] |
| `post_processing.alert_latency`, `delivery_delay` | true | boolean |
| `post_processing.alert_lookback_hours`, `delivery_requirement_hours` | 72, 24 | > 0 [h] |
| `dashboard.open_live_viewer`, `open_receiver_log`, `open_emitter_log` | true | boolean |
| `supervision.on_component_failure` | `"abort"` | `"abort"`, `"continue"`, `"restart"` |
| `supervision.max_restarts` | 3 | integer ≥ 0 |

Storage is checked before the run: `check_storage_limits` prints a
per-artifact estimate derived from the configuration (payload, metadata,
event logs, metrics, masks, plots, logs, file count) and enforces the
`[storage]` budgets. With `[retention]` disabled, a projected overrun
aborts before any directory is created. With the retention custodian
enabled, the run proceeds with a warning while the steady-state footprint
fits the budget: the non-prunable classes plus the delivered payload
capped at `high_watermark_gb`. The custodian prunes delivered
`ground/<batch>/seg_*.csv` payload copies, oldest ingested first and each
at least `grace_hours` of mission time after its ingestion, and records
each pruning as a `pruned` event. Event logs, metrics, masks, snapshots,
and `lost/` are kept. Log files rotate at `log_rotate_mb` whether or not
retention is enabled.

### Mission Clock

`simulation.mode` selects the clock the mission runs on
([Mission Clocks: Wall and Tick](@ref)). `"wall"`, the default, paces
mission time against the wall clock and reads `speed_up` and `mission_wall_seconds`; `"tick"`
advances mission time logically from one component wakeup to the next and
reads `mission_days` instead. The two key sets are disjoint: a `speed_up`
or `mission_wall_seconds` in tick mode, or a `mission_days` in wall mode,
is a configuration error naming the mode, and tick mode also rejects
`dashboard.receiver_status_panel = true`. `scenarios/deterministic_1d.toml`
is the library's tick scenario, one mission day. Any wall scenario runs on
the tick clock with its span unchanged through `--tick` on the command line
(`TelemetryCore.tick_configuration` in a session); the figures of this
manual are made that way.

### Scenario Library

The repository ships a library of complete configurations under
`scenarios/`, each runnable by path; `scenarios/README.md` carries the
coverage matrix and the expected regime of every file. `config.toml` at the
package root is the default entry point and is a copy of
`scenarios/recovery_12h_seasonal.toml`. The TOML comments give each key's
meaning, admissible choices, and safe interval; the scenario rationale is in
the library README and below.

The reference scenario, **recovery at the seasonal peak**, spans 7 mission
days from 30 March 2035 in about 3 min of wall time. It runs the physical
link, 230 kbit/s downlink against 75 kbit/s production, flat within the
pass (the sustained rate of the Definition Study Report,
[Link Capacity and the 24-Hour Requirement](@ref)). The 4-hour seasonal
extension, evaluated on the date of each pass, widens the daily 8-hour
window to 12-hour passes: 30 March is the peak day, and the extension stays
within minutes of its maximum over the week. The mission opens with a 2-day blind-spot backlog (288 batches at the shipped
physics: 60 s segments, 10 segments per batch → 144 batches/day) served by
12-hour passes of about 210 batches each over a bursty Gilbert–Elliott channel
(sticky BAD state, 50 % loss while BAD). Three scheduled events stress the
mission: a 15-minute antenna repointing on day 1.5 (a generation gap), a
day-2.5 full blackout after a solar particle event (18 h, then a 12 h
linear recovery ramp with 5× elevated loss), and a day-5.0 partial DSN
outage (severity 0.8, 12 h, 6 h ramp, 3× loss). An event marker at 14:00
on day 4 triggers, six hours later, a 3-hour low-latency period at half
capacity.

`scenarios/stress_8h_bursty.toml` runs the same disruption timeline on
plain 8-hour passes with the seasonal term disabled: the link delivers 138
batches per day against 144 produced, and the backlog grows.
`scenarios/nominal_8h.toml` is the balanced case without backlog or
disruptions, and `scenarios/abstraction_gaussian_peak.toml` the
peak-capacity abstraction, a 60 batches/h peak under a Gaussian profile.
The library also covers a drop policy, an explicit pass schedule, a 30-day
seasonal mission reaching the recorder ceiling, the coarse-batch regime of
2400 s segments, external ingestion, and one mission day on the tick clock.

Under the physical rate pair and 8-hour passes only the flat profile
sustains production. A day's capacity is the link rate times the pass
length times the profile mean: flat 1.0, sigmoid with k = 10: 0.93, sine
0.5, Gaussian with σ = 0.15: 0.38. The shaped profiles are stress
abstractions of a partially usable pass. `validate_config` warns when the
rate pair meets a shaped profile, stating the profile mean and the capacity of one nominal pass against the
daily production (`TelemetryCore.capacity_balance`), and the mission banner
prints the same balance as its `Capacity:` line for every run.

Every scenario without a seasonal term starts on 1 January 2035, the
calendar epoch of the ground-segment conventions, where the date labels the
time axis and does not act on the passes. In the two seasonal scenarios the
start date sets the phase of the extension, which is then evaluated on the
calendar date of each pass: a mission spanning months sees its passes
lengthen and shorten with the season
([Contact Schedule and Low-Latency Periods](@ref)).

A scenario runs by path ([Running the Simulation](@ref)):
```bash
julia scripts/run_full_sim.jl MY_RUN scenarios/stress_8h_bursty.toml
```
Each run archives the configuration it used as `config_snapshot.toml`, and
post-processing reads that snapshot.

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
label = "ground outage"     # optional display name on the dashboard status line
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

The on-board recorder is bounded by `[telemetry] onboard_capacity_days`
(default 14): once the buffer holds that many days of production, new
batches are discarded until room returns (no eviction), and the loss is
recorded as a `RECORDER` gap in the transmit event log.

`simulation.rng_seed` seeds the packet-loss channel, the run's only random
stream; the synthetic payload is declared by the event markers and involves
no draw. The same seed gives the same record on either clock
([Mission Clocks: Wall and Tick](@ref)).

### Contact Schedule
`[contacts]` shapes the daily window of `[telemetry]`; every key is optional.
```toml
[contacts]
seasonal_extension_hours = 4.0      # evaluated on each pass's date: 8 h at the trough, 12 h at the peak
season_peak_day_of_year = 89.0
low_latency_enabled = true          # set to false for the counterfactual run

[[contacts.exceptions]]             # the window of one date, as given
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

### Label Spans
`[[labels]]` entries declare labeled spans of payload rows, such as the samples of an injected event that a payload exporter records beside the series it writes. The run writes them to `label_spans.csv` with the other labeled intervals of the scenario (disruption phases, generation gaps, contact passes, low-latency periods, the initial downtime), where a consumer reads them. A `[payload]` section, the provenance a payload exporter records with its scenario fragment, is carried into the snapshot unchecked.
```toml
[[labels]]
label = "mbhb_1"
label_start_index = 100   # payload rows, inclusive; start > end declares an empty span
label_end_index = 2500
```

### Synthetic Payload
With `data_source = "synthetic"` the payload is a binary flag series: a segment is `1` throughout when its content span holds the instant of an `[[events.markers]]` entry and `0` throughout otherwise. `segment_duration_sec` must be a whole number of milliseconds and hold at least one sample at `sample_rate`.

### External Data Ingestion
An external high-frequency CSV time series replaces the synthetic payload with:
```toml
[physics]
data_source = "external"
external_data_path = "path/to/data.csv"
external_data_columns = []    # or ["A", "E"]: the file's columns to ingest, in order
sample_rate = 1024.0
segment_duration_sec = 60.0
batch_size = 15
```
Row `r` of the series is the sample at `start_sim_time − initial_downtime_days · 86 400 s + (r − 1) / sample_rate`: the first rows fill the pre-existing blind-spot backlog, a generation gap skips the rows of its interval, and past the last row the payload is zero. Each batch records the row of its first sample (`payload_row`, [Batch Identity → Sample Interval](@ref)).

A file may carry several columns. `external_data_columns` names those to ingest, in that order; left empty, the `Amplitude` column is taken, or else the first column, under the name `Amplitude`. The ingested columns form one payload and share each batch, transfer and loss draw. Each segment file carries one column per payload column under its name. The names are stamped into the run's provenance and descriptor, and the adapter reads one column (`read_batch`) or all of them (`read_batch_matrix`). A listed column absent from the file's header is rejected at validation.

## Running the Simulation
The emitter and the receiver run as cooperative tasks on one thread in both
modes, so Julia needs no thread option.

**Interactive Dashboard:**
```bash
julia scripts/launch_dashboard.jl
```
This spawns the log terminals and the `UnicodePlots` live viewer, which redraws only on a state change, for each `[dashboard]` flag `open_*` set to `true`; the shipped configurations set them `false`.

**Headless Mode:**
```bash
julia scripts/run_full_sim.jl
julia scripts/run_full_sim.jl --tick MY_RUN scenarios/stress_8h_bursty.toml
```
The arguments are optional and order-independent. One ending in `.toml`
selects the configuration (a relative path resolves against the current
directory, then the package root), `--tick` runs it on the tick clock, and
any other argument sets the run ID. The receiver's console status panel (a
text panel redrawn on every receiver iteration, which clears the terminal)
is off by default; `dashboard.receiver_status_panel = true` enables it for a
headless run whose terminal shows nothing else.

## Ensembles and Sweeps
A sweep runs one configuration on the tick clock once per seed, with
optional overrides of any key, and gathers the realized totals of every
run into one table. Any run of the table can be regenerated exactly from
its seed and the sweep's provenance:
```bash
julia scripts/run_sweep.jl scenarios/stress_8h_bursty.toml MY_SWEEP --seeds 1:8 --workers 4 --set packet_loss.p_loss_bad=0.6
```
`--seeds` takes a range (`a:b` or `a:step:b`) or a comma-separated list. `--workers N` runs `N`
members at once as tasks on `N` Julia threads (serial without it); the
script restarts itself with `--threads=N` when Julia was started with
fewer. On the tick clock the runs are independent of the host's load and
share no state, so parallel runs reproduce the serial ones exactly. Every
`--set section.key=value` applies to all runs; the value is read as a
boolean, an integer, a float, or else a string (quotes optional), and a
key outside the configuration schema is refused. The runs land under
`data/runs/<PREFIX>_seed<seed>/`, and their post-processing writes the gap table and the metrology tables but no
figures and no mask timeline. `data/sweeps/<PREFIX>/` receives
`summary.csv`, one row per run with the seed and the totals of
`Sweeps.summarize_run`: the generated and delivered counts, live and
archive, lost, failed transfers (column `retries`), the buffer and link at
the end, the share within the delivery requirement over all batches and
over the resolved ones, the pending and discarded counts, the alert-latency
medians at 24 h and 72 h under the realized doctrine and the FIFO drain,
complete-case and Kaplan–Meier, and the hole count. Beside it, `sweep.toml` records the sweep's
provenance: the base configuration's hash, the overrides, the seeds, the
commit and version, the date. In a session, `Sweeps.run_sweep(cfg; prefix, seeds,
overrides, workers)` returns the table and the directory, and
`Sweeps.summarize_run(run_dir)` reads one run's totals.

## Post-Processing & Masks
After a run, post-processing writes `masks/telemetry_mask_timeline.csv`, a 2D matrix of the state of every batch (`0=Future`, `1=Onboard`, `2=Link`, `3=Ground`, `4=Lost`) at every telemetry event. The reconstruction is exact: the emitter and receiver append every batch milestone to `events_tx.csv` / `events_rx.csv` (generation, transmission, ingest, retry, loss), and post-processing replays those ground-truth logs.

A run whose `config_snapshot.toml` is missing or unparsable is refused with a `[CONFIG]` error.

Before any figure, post-processing writes the gap table `masks/gaps.csv`. It lists every hole of the delivered record as a payload-row interval with its cause: a lost or pruned batch, a batch undelivered at run end, a generation gap by type (`stream`, `scheduled`, `recorder`), or the unreached tail of an external record. A gap-aware analysis takes it as its declared input ([Stationary Analysis](@ref)), and `Masks.gap_table(run_dir)` computes it for a run made before the product existed.

The declared-hole feed `holes.csv` is appended during the run as each hole is declared. Post-processing settles it from the gap table, appending the end-of-run holes with the nominal mission end as their declaration instant, after which the feed and the table agree. A row of the feed that the table does not derive is reported as a warning in the run log (`Masks.hole_feed_excess`); the table is the reference. The label-span table `label_spans.csv` is written at mission start and regenerated here only when a run lacks it.

Last, post-processing writes `descriptor.toml`, the run's identity for a downstream collection: producer version and source identity (tree hash and commit, also for a copy installed by Pkg), configuration hash, seed, clock mode, payload geometry, and the size and SHA-256 of every table present.

The products are written in order of cost: the gap table, the settled hole feed and the label spans, the metrology tables, then the alert-latency and delivery-delay figures, the mask timeline and the raster drawn from it, the mission summary and the session figures, the exports, and the run descriptor. A run whose supervisor process was killed during that stage is completed with `scripts/postprocessing/complete_run.jl` ([Availability Window & Lifecycle Sentinels](@ref)).

With `hdf5_export = true` in `[post_processing]` every table product (event logs, hole feed, metrics, mask timeline, batch epochs, gap table, metrology tables, markers, label spans, component events) is additionally written to `products.h5` with the run's provenance as attributes ([HDF5 Product Export](@ref)); the same file can be produced afterward for any run:
```bash
julia scripts/postprocessing/export_hdf5.jl [RUN_ID]
```

## Publication Figures
`[post_processing.publication]` re-renders the figures of a run (mission
summary, session figures, alert latency, delivery delay, batch-state
raster) at a declared printed width in a vector format, into one directory with a
`PROVENANCE.toml` sidecar (run ID, package version, git commit, snapshot
hash, file list), each file named `<stem>__<run_id>.<format>`:
```toml
[post_processing.publication]
enabled = true
format = "pdf"              # or "svg"
column_width_mm = 120.0     # printed width [mm], 100 to 400; default 178
export_dir = "figures_export"     # "" = <run_dir>/publication; relative to the current directory
```
Every figure is composed at one standard layout (1200 Makie units wide,
26-unit type) and the export scales it as a whole, so a narrower figure is a
miniature of the standard one: at 178 mm the axis labels print at about
11 pt and the tick labels at about 9 pt, at the 100 mm floor at about 6 pt
and 5 pt. The same export runs afterward for any run with the settings of
its snapshot:
```bash
julia scripts/postprocessing/export_publication_figures.jl [RUN_ID]
```

## Session Figures of Long Missions
Each contact window, nominal pass or low-latency period, receives a session
figure (`session_day<kk>_detail.png`, `session_day<kk>_low_latency_detail.png`),
so their number grows with the mission: a year of daily passes is
365 figures, about a second and 0.6 MB each. Two keys bound the stage:
```toml
[post_processing]
session_figures = true      # false: the mission summary only
session_figures_max = 0     # at most this many, evenly spaced over the contacts; 0 = no cap
```
Under a cap the windows are spread evenly over the mission, the first and
the last included. The keys are read from the run's own snapshot, so the
publication export and a later call of
`MissionFigures.generate_mission_plots` select the same windows.

The stage holds one figure in memory at a time: each figure is drawn in a
theme scope of its own and released after it is saved, so its memory does
not grow with the number of windows. The start-up estimate prints it as
`Figure RAM` and checks it against `storage.max_ram_gb`, beside the replay
RAM of the mask timeline.

Above 120 mission days the capacity panel of the mission summary shows the
mean capacity of each mission day, and its legend says so; passes drawn one
by one would merge into a solid block. An 8-hour pass then reads as a third
of the day, a missed pass as zero, and the seasonal extension as the slow
rise and fall of that level. Count axes that reach 10⁴ batches carry tick
labels with one common power of ten (`10⁴`, `2×10⁴`, …).

## Batch-State Raster
One further figure follows every run, behind its own flag:
```toml
[post_processing]
state_raster = true         # the batch-state timeline as a raster
```
`state_raster.png` draws `masks/telemetry_mask_timeline.csv` with one column
per batch, one row per recorded event, and one color per state, in the live
and archive colors of every other figure. The [Scenario Gallery](@ref) shows how
to read it. It needs `generate_mask_timeline`, and is skipped without it.

## GIF Animation
To visualize the LIFO/FIFO routing physics of a completed run:
```bash
julia scripts/postprocessing/generate_gif.jl [--web] [RUN_ID]
```
Each frame is one row of `mission_profile.csv` and states the mission
clock, the link state, and the buffer counters. The rows follow a
change-driven cadence, so the animation is not linear in mission time. Two
rendering profiles exist: the default archive profile (1400 units wide, two raster units each,
at most 800 frames) and `--web`, which writes the size the README and the
manual carry (900 px, at most 240 frames, a few megabytes) as
`telemetry_animation_web.gif`.