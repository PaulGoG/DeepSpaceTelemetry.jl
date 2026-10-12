# Analysis Interfaces

The framework couples to external data-analysis pipelines — streaming
consumers that follow an active run (sliding-window searches, alert
generators, online estimators) and stationary consumers that open a finished
one (post-hoc replays, gap-aware statistics, cross-run comparisons) —
exclusively through the filesystem. There is no in-memory API to link against: every interface below
is a file contract, so consumers may be written in any language and any number
of analysis instances may operate concurrently on a single telemetry run.

## Design Principles

1. **Consumers are read/copy-only.** Analysis processes must never create,
   modify, move, or delete anything inside a run directory. Data a pipeline
   needs to own is copied out to consumer-managed storage.
2. **Concurrent consumers are safe by construction.** All consumer-facing
   files are either append-only (event logs, metrics) or appear atomically
   and are immutable afterward (batch directories). No locking protocol
   exists or is needed — provided rule 1 is respected.
3. **The contract is invariant under `speed_up` and under the clock mode.**
   A consumer developed against an accelerated run (`speed_up = 3600`)
   works unchanged against a real-time run (`speed_up = 1.0`) or a tick-mode
   run (`simulation.mode = "tick"`); only the wall-clock arrival cadence
   differs. Development runs accelerated or on the tick clock, where a run
   reproduces to the byte; rehearsal runs at mission cadence.
4. **`config_snapshot.toml` is the only source of derived quantities.**
   Sample rates, segment/batch geometry, and session parameters are read from
   the run's own snapshot, never from the live `config.toml`.
5. **The public surface is this contract, the configuration schema, and the
   entry-point scripts.** Semantic versioning applies to those three: a
   change that alters what a consumer reads from a run directory, rejects a
   configuration that was accepted, or changes a script's arguments or
   products is a major release. The Julia modules and functions are the
   implementation and may change between minor releases; the API pages
   document them for contributors.

## Two Consumer Classes

A run serves two kinds of analysis, and the contract below is organized
around them.

A **streaming consumer** attaches to an *active* run and reacts to
arrivals as they happen: a sliding-window search that scores every window
the moment its data are on the ground, an alert generator, an online
estimator that updates a statistic sample by sample. It owns state (what is
covered, what is pending, what is a hole), sees the data out of temporal
order, and must decide what to do with windows that may never fill.

A **stationary consumer** opens a *finished* run as a fixed record: a
post-hoc replay of the arrival stream for a latency study, a batch analysis
of the delivered series with its gaps declared, a comparison across runs. It
may read everything, including the products post-processing derives from the
record, and nothing it reads will change.

| | Streaming (active run) | Stationary (finished run) |
|---|---|---|
| Sentinel to check | `RUN_ACTIVE` present, heartbeats fresh | `RUN_COMPLETE` (or `RUN_ABORTED`: a truncated but consistent record) |
| Source of truth | `events_rx.csv`, tailed, plus the batch directories it names | the batch directories, the two event logs, `mission_profile.csv`, and everything post-processing derived from them |
| Order of the data | arrival order: the live front FIFO, the backlog LIFO behind it | any order; the record is complete |
| What can still change | new batches, `lost` and `pruned` events, a declared gap closing, the terminal sentinel | nothing |
| Gaps | holes that may close (undelivered yet) or are permanent (`lost`, a generation gap) | declared intervals with a cause |
| State | the consumer's: coverage, pending windows, horizon | none required; the mask timeline carries the live view at every snapshot |
| Read with | [Streaming Consumption](@ref) | [Stationary Analysis](@ref) |

The two meet at the terminal sentinel: a streaming consumer that sees
`RUN_COMPLETE` appear may finish as a stationary one, and a stationary
consumer that replays `events_rx.csv` in `SimTime` order reproduces exactly
what a streaming consumer saw. The design principles above hold for both;
the file contract is the same, read at different moments.

## The Run-Directory Contract

`data/runs/<RUN_ID>/` contents, from a consumer's perspective:

| Artifact | Writer | Consumer access |
|---|---|---|
| `ground/<BATCH>/` | receiver | **Read/copy.** The delivery surface (see below). |
| `lost/<BATCH>/` | receiver | Read/copy. Retry-exhausted batches, preserved but never ground-available. |
| `events_rx.csv` | receiver (single writer) | **Tail/read.** The authoritative arrival feed. |
| `events_tx.csv` | emitter; the supervisor appends the `STREAM` gap pair while the emitter is down (one live writer at a time) | Tail/read. Generation and transmission milestones. |
| `mission_profile.csv` | receiver | Tail/read. Link and buffer metrics at a change-driven cadence, columns `SimTime, WallTime, Mission_Day, Hours_Elapsed, Bandwidth_Pct, Onboard_Buffer, Link_Buffer, Ground_Total, Ground_Live, Ground_Arch, Nominal_Bandwidth_Pct, Lost_Count, Retry_Count, Disruption_Active` (a pre-rename `Ground_Archive` column is normalized to `Ground_Total` on read). |
| `masks/` | post-processing | Read/copy. Batch-state timeline and point-wise expansions. |
| `config_snapshot.toml` | pipeline (at startup) | Read. Exact run parameters plus `[provenance.platform]` — `package_version`, `git_commit`, `git_dirty` (uncommitted changes in the checkout), `hostname`, `os`, `cpu_model`, `logical_cores`, `total_memory_gb`, `julia_version`, `versioninfo`, `julia_threads`, `blas_threads` — the parameter hash `config_sha256` at `[provenance]` (the SHA-256 of the configuration as sorted TOML without that section; its first eight hex digits open the run identifier `RUN_cfg=<hash>_pid=<pid>_t=<yyyymmdd_HHMMSS>`), the payload origin `payload_origin` at `[provenance]` (the content instant of payload row 1, `start_sim_time` less `initial_downtime_days`, as an ISO-8601 string; see Batch Identity below), and, for external data, the input identity there (`external_data_path`, `external_data_rows`, `external_data_sha256`, `declared_sample_rate`). |
| `manifest_snapshot.toml` | pipeline (at startup) | Read. The manifest of the environment the run was resolved on: the exact version of every dependency. Manifests are not tracked in the repository, so this file and the commit in `config_snapshot.toml` together fix the code state. |
| `RUN_ACTIVE` / `RUN_POSTPROCESSING` / `RUN_COMPLETE` / `RUN_ABORTED` | pipeline | Read. Lifecycle sentinels (see below). |
| `clock_anchor.toml` | pipeline (at mission start) | Read. Persisted mission-clock anchor and absolute deadline (`wall_epoch`, `start_sim_time`, `speed_up`, `deadline_wall`); re-attaching components reconstruct the identical clock from it. |
| `component_events.csv` | supervisor (single writer) | Tail/read. Component lifecycle record, columns `SimTime, Component, Event`, with `Component` either `emitter` or `receiver` and `Event` one of `down`, `restart`, `stalled`, `recovered`. |
| `emitter_alive` / `receiver_alive` | components (heartbeats) | Read mtime. Liveness signals, refreshed ≈ 1 s while a component runs and deleted when it exits: absence means finished, a stale mtime means stalled. |
| `markers.csv` | pipeline (at mission start) | Read. Event markers of the run (`SimTime, Label`) — the instants the alert-latency metric is evaluated at (`alert_latency_markers.csv`). |
| `delivery_delay.csv` | post-processing | Read. Measurement-to-ground delay of every generated batch, columns `Batch, Live, ContentEnd, AvailableAt, Delay_Hours, LowLatency` (`AvailableAt` and `Delay_Hours` missing for undelivered batches; `LowLatency` flags deliveries inside a low-latency period); `plots/delivery_delay.png` renders the distribution against the requirement. |
| `alert_latency.csv` | post-processing | Read. Alert-latency curves — median and quartiles of the ground availability of look-back data after a live event, realized doctrine against the counterfactual FIFO drain — columns `Lookback_Hours, N_Alerts, LIFO_Median_Hours, LIFO_Q25_Hours, LIFO_Q75_Hours, FIFO_Median_Hours, FIFO_Q25_Hours, FIFO_Q75_Hours`; `plots/alert_latency.png` renders the curves. |
| `alert_latency_markers.csv` | post-processing | Read. The alert latency at every event marker, columns `Label, Marker, Batch, Lookback_Hours, LIFO_Hours, FIFO_Hours`. |
| `products.h5` | post-processing (`hdf5_export`) | Read/copy. The tabular products, the mask timeline, the point-wise masks, and the provenance attributes in one HDF5 file (section below) — not the batch payloads, the clock anchor, the sentinels, or the logs; regenerable from the CSV products. |
| `plots/` | post-processing | Read/copy. Figures `mission_summary_global`, one `session_<stem>_detail` per contact, `alert_latency`, `delivery_delay`, and `state_raster` (the batch-state timeline as a raster), each as `.png` and `.pdf`. |
| `publication/` | post-processing (`[post_processing.publication]`) | Read/copy. Journal-width figure export, `<stem>__<run_id>.<format>`, with a `PROVENANCE.toml` sidecar (`[export]`: `run_id`, `run_directory`, `exported_at`, `column_width_mm`, `format`, `package_version`, `git_commit`, `config_snapshot_sha256`, `figures`). |
| `masks/gaps.csv` | post-processing | Read. Every hole of the delivered record as a declared interval with its cause, columns `Cause, Batch, RowFirst, RowLast, ContentStart, ContentEnd` (Stationary Analysis below): the input of a gap-aware consumer, written first among the products. |
| `masks/batch_epochs.csv` | post-processing | Read. Batch → epoch map, columns `Batch, GenSimTime, ContentEpoch, PayloadRow`: the finalization instant from the event log, and the first-sample timestamp and payload row from the batch metadata (missing when the metadata lacks them, as in runs before 2.1.0); written when the run has `gen` rows, it re-anchors point-wise mask rows on the mission timeline and the payload when gap events are present. |
| `masks/pointwise_mask_final.csv`, `masks/pointwise_mask_t<row>.csv` | post-processing | Read. Point-wise expansions of one mask-timeline row (the final row and every requested `target_event_rows` entry), columns `Time_Index, Ground_Available`. |
| `HALT` | **operator** | **The one sanctioned external write**: `touch HALT` stops both components cleanly at their next iteration; the pipeline removes the file once the components have joined, before post-processing. |
| `emitter.log`, `receiver.log`, `supervisor.log` | logger | Read. Human diagnostics — the two component logs, and the supervisor's `[SUPERVISOR]`, `[POST]`, and `[CONFIG]` records of the mission and its post-processing — rotated to `<name>#k.log` at `retention.log_rotate_mb`; not machine-parsed interfaces. |
| `onboard/`, `link/` | emitter/receiver | **Off-limits.** Internal staging; the emitter counts in-flight batches from the `link/` listing, so a slot frees when the receiver moves a batch out. |

A batch directory contains `metadata.json` and one `seg_<id>.csv` per segment
(single `Amplitude` column; a synthetic run writes the flag values `0.0` and
`1.0` there, an external run the ingested samples). The metadata keys are `batch_id`,
`segment_count`, `content_epoch` — the mission timestamp of the payload's
first sample, i.e. the physical epoch the data belong to — `payload_row` —
the payload row of that first sample (Batch Identity below) — and
`created_at` — the mission instant at which the batch was finalized and
became transmittable (never earlier than the content end, and within one
segment period of it when the host keeps pace with the accelerated clock).
Segment files carry no timestamps; sample `k` of a batch lies at
`content_epoch + (k − 1) / sample_rate` and is payload row
`payload_row + k − 1`. A batch whose payload holds an event marker carries
the marker labels under the optional `markers` key. The order of the keys
in `metadata.json` carries no meaning.

Instants in the CSV tables (`SimTime`, `WallTime`, `GenSimTime`,
`ContentEpoch`, `ContentEnd`, `AvailableAt`, `Marker`) are written as
`yyyy-mm-ddTHH:MM:SS.s`, the seconds with one to three decimals
(`2035-01-04T12:00:36.0`, `2026-09-24T02:01:17.051`). The package states
that form when it writes and the column types when it reads
(`TelemetryCore.write_table`, `TelemetryCore.read_table`), so neither
follows the defaults of the CSV library in use.
Batches are delivered by an atomic same-filesystem `mv`: a directory visible
under `ground/` is complete, and it is never modified afterward except by
the retention custodian (below).

### Provenance conventions

The run directory follows the conventions of DrWatson's provenance tooling
without the dependency: the layout is written batch by batch by two
concurrent components and its provenance is recorded at setup, which the
whole-file semantics of `tagsave` and `safesave` do not cover. The
correspondence is one-to-one.

| DrWatson | This package |
|---|---|
| `savename` — parameter-derived identifier | `TelemetryCore.generate_run_id` — `RUN_cfg=<8 hex of config_sha256>_pid=<pid>_t=<yyyymmdd_HHMMSS>`, key=value fields in `savename` order |
| `tagsave` — the git commit stored with the result | `TelemetryCore.setup_run_dir` — `config_snapshot.toml` with `[provenance.platform]` (commit and dirty flag, hostname, hardware, Julia and package versions) beside `manifest_snapshot.toml` |
| `safesave` — `#k` backup rotation, never an overwrite | `TelemetryCore.backup_existing` and `backup_existing_dir` — the same `<name>#k` rotation for every result file and run directory |
| `produce_or_load` — cached expensive stages | not provided: the mission runs in real time and cannot be replayed from a cache, and every post-processing product is regenerable from the run directory by the standalone scripts |
| `datadir`, `projectdir` | `TelemetryCore.run_directory` — `<checkout>/data/runs/<RUN_ID>` |

## Availability Window & Lifecycle Sentinels

With `[retention]` disabled (the default), nothing is deleted from a run
directory while the simulation is active — delivered payloads persist for the
run's lifetime, and the only deletion path in the framework is the
interactive `scripts/maintenance/cleanup.jl`.

With `retention.enabled = true`, the receiver's custodian bounds the
delivered-payload footprint: **a batch's payload is guaranteed readable for
`retention.grace_hours` of mission time after its `ingested` event** — a
pipeline copies what it needs within that window. Beyond it, once the payload
tally exceeds `retention.high_watermark_gb`, the oldest-ingested batches lose
their `seg_*.csv` files; the batch directory remains, keeps `metadata.json`,
gains a zero-byte `PRUNED` marker, and a `pruned` row (state-preserving,
`Attempt = 0`) is appended to `events_rx.csv`. Consumers must tolerate both
the marker and the event value. Event logs, metrics, masks, snapshots, and
`lost/` are never pruned, so post-hoc replay and mask products are unaffected.
Time-based retention deliberately requires no consumer registration — that
would make consumers writers.

Run lifecycle is signaled by sentinel files in the run directory:
`RUN_ACTIVE` exists while the pipeline may still write; it is replaced by
`RUN_COMPLETE` when the lifecycle ends (including after reported component
failures — the sentinel marks "no further writes", not success) or by
`RUN_ABORTED` when the pipeline exits before its lifecycle completes. A
consumer may treat either terminal sentinel as the signal to switch from
tailing to batch processing.

`RUN_POSTPROCESSING` stands beside `RUN_ACTIVE` from the moment the emitter
and the receiver have stopped until the lifecycle ends: while it is present
the payload, the event logs, and the metrics profile are final, and only
derived products (metrology tables, masks, figures, exports) are still
written. The metrology tables come first, the figures last.

The terminal sentinels are written by the supervisor process as it leaves.
A process killed from outside (by the kernel's out-of-memory handler, by a
scheduler at its time limit) leaves `RUN_ACTIVE` behind with no process to
remove it. Such a directory is a stranded run, not a live one: its deadline
in `clock_anchor.toml` has passed and nothing writes to it. It is settled
with
```bash
julia --threads=3 scripts/postprocessing/complete_run.jl <RUN_ID>
```
which runs the post-processing again from the data on disk, with the
settings of the run's own snapshot, and replaces `RUN_ACTIVE` by
`RUN_COMPLETE` when the mission phase had ended, or by `RUN_ABORTED` when
the process died before the mission deadline and the record is truncated.
The mission phase counts as ended when `RUN_POSTPROCESSING` is present; for
a run made before that sentinel existed, when the metrics profile reaches
the deadline. The script refuses a run whose deadline has not passed and,
without `--force`, a directory written to within the last minute.

## Component Outages & Generation Gaps

The two components run under a supervisor (`[supervision]` in the config):
on a component failure the policy `abort`s the run cleanly, `continue`s
one-sided, or `restart`s the component (bounded attempts). Consumers observe
outages through `component_events.csv` and the heartbeat mtimes. A receiver
outage needs no special handling — it reproduces ground-station-blackout
phenomenology (backlog accumulation, then drain). An **emitter outage is a
genuine generation gap**: the restarted instrument resumes at the first
segment boundary at or after the *current* mission time, on the sampling
grid of the payload origin, and the dead window is bounded by
`gap_start`/`gap_end` rows (Batch = `STREAM`) in `events_tx.csv`: `gap_start`
is the last event-log instant before the outage (the partial batch the
failed emitter held is lost with it), `gap_end` the resumption instant. The
same row pair bounds a **scheduled
generation gap** (a disruption event with `affects = "generation"`; Batch =
`SCHEDULED`), whose `gap_start` is the first discarded content instant and
whose `gap_end` is the scheduled end rounded up to the segment grid, so
`[gap_start, gap_end)` is exactly the content not recorded;
and a **recorder overflow** (the on-board buffer at
`storage.onboard_capacity_days`; Batch = `RECORDER`, closed when room
returns), during which the discarded data are generated and dropped, so the
stream continues without a jump. No gap shifts the sampling grid: segment
identifiers and payload rows continue from the content epoch. Because batch
IDs stay contiguous while mission time is not, point-wise mask rows must be
re-anchored — through `payload_row` or `masks/batch_epochs.csv` — when gap
events are present; the mask replay itself treats gap events as
state-preserving.

## Event Feeds

`events_rx.csv` — columns `SimTime, Batch, Event, Attempt`; `Attempt` is
populated on every row:

* `ingested` — the batch reached the ground archive; `Attempt` is the
  number of failed attempts before the successful transfer (`0` for a batch
  reconciled at receiver start-up). **Ordering guarantee:** the payload is
  moved into `ground/` *before* this row is appended, so a consumer that
  reads an `ingested` event may open the batch immediately.
* `retry` — a transfer attempt was lost; the batch remains on the link and
  is re-served no earlier than one round-trip light time later, other
  in-flight batches first. `Attempt` counts failed attempts so far.
* `lost` — retry budget exhausted (`Attempt` = `max_retries + 1`); the
  batch was moved to `lost/` (also before the row is appended) and will
  never become ground-available.
* `pruned` — the retention custodian removed the payload of a delivered
  batch (`Attempt` = `0`); the `PRUNED` marker and `metadata.json` remain
  (Retention above).

`events_tx.csv` — columns `SimTime, Batch, Event`, with `gen` (batch
finalized onboard), `tx` (batch placed on the downlink), `marker`
(`SimTime` = an event-marker instant, `Batch` = the batch holding it,
appended when that batch is finalized; state-preserving), and the
`gap_start` / `gap_end` pair bounding a generation gap (`Batch` = `STREAM`,
`SCHEDULED`, or `RECORDER`, see above; state-preserving).

## Batch Identity → Sample Interval

Batch names are `LIVE_batch_<k>` (generated during a contact — a nominal
pass or a low-latency period) or `ARCH_batch_<k>` (generated in a blind
spot or blackout); `k` is the global
1-based batch index.

The payload is sampled on one grid for the whole run, anchored at the
payload origin `t₀` (`[provenance] payload_origin` in
`config_snapshot.toml`): payload row `r` is the sample at
`t₀ + (r − 1) / sample_rate`. In external mode row `r` is data row `r` of the
input CSV (header excluded); rows past its end are zeros. A batch with
content epoch `e` starts at the row

```
payload_row = (e − t₀) · sample_rate + 1
```

stamped in its `metadata.json`, and holds the rows
`payload_row … payload_row + points_per_batch − 1`, with

```
points_per_batch = sample_rate × segment_duration_sec × batch_size
```

(all three from `config_snapshot.toml` `[physics]`). Segment identifiers are
grid positions as well: `seg_<id>.csv` opens at
`t₀ + (id − 1) · segment_duration_sec`, so identifiers never repeat within a
run and a gap skips the identifiers of the segments it suppresses. The
mapping is row-exact when `sample_rate × segment_duration_sec` is an
integer, which validation warns about otherwise; the rows of consecutive
segments then remain consecutive and disjoint, with
`payload_row = (id − 1) · round(sample_rate × segment_duration_sec) + 1`.

Only in a run whose `events_tx.csv` has no `gap_start` row does batch `k`
cover the rows

```
[(k − 1) · points_per_batch + 1,  k · points_per_batch]
```

— the convention on which the point-wise masks are generated. With gaps
present, batch indices stay contiguous across the missing rows, and
`payload_row` is the reference.

## Streaming Consumption

A streaming consumer follows an active run through its arrival feed. The
loop has five parts: attach, follow the feed, maintain coverage, treat the
holes, and leave when the run ends.

**Attach.** Check that `RUN_ACTIVE` exists and that `receiver_alive` is
fresh (its mtime refreshes about once per wall second). Read
`config_snapshot.toml` once: `[physics]` gives the geometry
(`sample_rate`, `segment_duration_sec`, `batch_size`, hence
`points_per_batch`), `[simulation] start_sim_time` the mission epoch, and
`[provenance] payload_origin` the instant of payload row 1 (see Batch
Identity above); `external_data_rows` is the record length of an external
payload, beyond which the producer pads with zeros. Read `clock_anchor.toml`
if the consumer paces itself against mission time: `wall_epoch`,
`start_sim_time`, and `speed_up` convert a wall instant to a mission
instant, and `deadline_wall` is when the mission phase ends.

**Follow the feed.** `events_rx.csv` is append-only with a single writer,
and the payload of a batch is moved into `ground/` *before* its `ingested`
row is appended, so a consumer that keeps the count of rows it has consumed
and reads the rows beyond it on every poll never sees a batch it cannot
open. The four event values and the consumer's response:

| `Event` | Meaning | Response |
|---|---|---|
| `ingested` | the batch is in `ground/`; `Attempt` counts the failed transfers before it | map the batch to its rows, read its segments, extend the coverage |
| `retry` | a transfer was lost; the batch stays on the link and is re-served after one round-trip light time | none (state-preserving); it tells the consumer that the batch is coming late |
| `lost` | the retry budget is exhausted; the batch is in `lost/` and will never be on the ground | a permanent hole: discard or gap-handle the windows that cross it, never wait on it |
| `pruned` | the retention custodian removed the payload of a delivered batch; `metadata.json` and a `PRUNED` marker remain | the rows stay covered for a consumer that copied the payload within `retention.grace_hours`; otherwise a hole |

The poll interval follows the cadence of the run: one segment per
`segment_duration_sec / speed_up` wall seconds, a batch every `batch_size`
segments. Polling a few times per batch period is enough; at `speed_up = 1`
that is minutes. Under the tick clock there is no wall mapping and arrivals
come as fast as the host processes them, so a consumer following a tick
run polls as fast as it can and is best developed against the finished
record instead. For a long run, tail by byte offset rather than re-reading
the file.

**Maintain coverage.** A batch covers the payload rows `payload_row …
payload_row + points_per_batch − 1` of its `metadata.json`; sample `k` of
the batch lies at `content_epoch + (k − 1) / sample_rate`. Keep the delivered
rows as a set of disjoint intervals. Arrival is out of temporal order by
design — live batches stream FIFO with priority, the blind-spot backlog
backfills LIFO (newest first) behind them — so coverage grows *backward in
time* from each live front, contiguously behind it, session by session. A
window is evaluable when the coverage spans it (fully, or to an acceptable
fraction with the holes known); evaluate it once, when that first becomes
true, and do not re-evaluate it when later batches arrive behind it unless
the analysis is meant to.

**Treat the holes.** A row not yet covered is in one of three states, and
the feed and the transmission log tell them apart:

* *Pending*: the batch was generated (`gen` row in `events_tx.csv`) and is
  on board or on the link. It will arrive, late; a window that needs it
  waits. The `retry` rows say how many attempts it has survived.
* *Permanent*: the batch is `lost`, or the rows were never generated — a
  generation gap bounded by the `gap_start` / `gap_end` pair of
  `events_tx.csv` (`Batch` = `STREAM` for an emitter outage, `SCHEDULED`
  for a scheduled gap, `RECORDER` for an overflow of the on-board recorder).
  Read those rows as they appear and declare the hole at once, rather than
  discovering it later from the spacing of the content epochs.
* *Unknown*: no `gen` row yet, because mission time has not reached the
  rows. Beyond the current mission instant nothing is pending.

A consumer that keeps an *order horizon* — a bound on how long it waits for
a pending batch before scoring without it — turns pending holes into
declared ones at the horizon; the realized arrival delays of the shipped
scenarios (`delivery_delay.csv`) are the reference for choosing it.

**Leave.** `RUN_POSTPROCESSING` appears beside `RUN_ACTIVE` when both
components have stopped: from then on the payload, the event logs, and
`mission_profile.csv` are final, and only derived products are still being
written. `RUN_COMPLETE` or `RUN_ABORTED` replaces `RUN_ACTIVE` when the
lifecycle ends; either is the signal to finish as a stationary consumer.
A run whose deadline has passed, whose heartbeats are stale, and which still
shows `RUN_ACTIVE` is stranded, not live; `complete_run.jl` settles it
(Availability Window above).

A minimal consumer in Julia, with the package as a reader (consumers in
other languages read the same files):

```julia
using DeepSpaceTelemetry: TelemetryCore
using Dates

run_dir = TelemetryCore.run_directory("RUN_ID")
cfg = TelemetryCore.load_run_config(run_dir)
phys = cfg["physics"]
points_per_batch = round(Int, phys["sample_rate"] * phys["segment_duration_sec"]) * phys["batch_size"]

segment_files(dir) = sort(
    filter(f -> occursin(r"^seg_\d+\.csv$", f), readdir(dir));
    by = f -> parse(Int, match(r"\d+", f).match),
)
read_payload(dir) = reduce(vcat, (TelemetryCore.load_segment(joinpath(dir, f)).data for f in segment_files(dir)))

covered = UnitRange{Int}[]          # delivered payload rows
holes = Pair{UnitRange{Int},Symbol}[] # permanent holes with their cause
consumed = 0
while true
    rx = TelemetryCore.read_table(joinpath(run_dir, "events_rx.csv"))
    for row in eachrow(rx[(consumed + 1):end, :])
        stage = row.Event == "lost" ? "lost" : "ground"
        meta = TelemetryCore.read_batch_metadata(joinpath(run_dir, stage, row.Batch))
        first = meta["payload_row"]
        rows = first:(first + points_per_batch - 1)
        if row.Event == "ingested"
            payload = read_payload(joinpath(run_dir, "ground", row.Batch))
            push!(covered, rows)        # feed `payload` at `rows` to the analysis
        elseif row.Event == "lost"
            push!(holes, rows => :lost)
        elseif row.Event == "pruned"
            push!(holes, rows => :pruned)
        end                             # `retry`: nothing to do
        consumed += 1
    end
    isfile(joinpath(run_dir, "RUN_ACTIVE")) || break
    sleep(poll_seconds)
end
```

The generation gaps enter the same `holes` list from `events_tx.csv`: every
`gap_start` row with `Batch` in `STREAM`, `SCHEDULED`, or `RECORDER` opens a
hole at the row of its instant, closed by the matching `gap_end` (the
conversion between an instant and a payload row is in Batch Identity
above). A batch directory written before 2.1.0 has no `payload_row`; such a
run has no gap rows either, and batch `k` then covers the rows
`(k − 1) · points_per_batch + 1 … k · points_per_batch`.

**Consumer archetypes.** The loop above is what a *streaming engine* does
generically — a coverage set, a window scheduler that emits each window
once, conditioning on the delivered stretch, a scorer, and an ordered commit
with an order horizon for stateful estimators — and such an engine is best
kept independent of this run directory behind a *run adapter* that answers
five questions:

```julia
run_geometry(run)      # sample rate, segment length, batch size, payload origin, record length
list_batches(run)      # per batch: name, index, live?, payload rows, content epoch,
                       #            state ∈ ground | lost | pruned
read_batch(run, name)  # the samples of one ground batch as Float32, segments in ascending id
arrival_events(run)    # (sim_time, batch, event, attempt) in mission-time order
run_state(run)         # active | complete | aborted, from the sentinels
```

Everything the adapter needs is in the snapshot, the batch directories, and
`events_rx.csv` (the sections above), and one adapter serves the engine's
follow mode on an active run and its replay mode on a finished one. A
*detector* — a classifier, a matched filter — then scores the conditioned
windows. An *online estimator* that requires strictly increasing sample
times fits the live FIFO front only; the LIFO backfill behind it is out of
order for such a consumer and is better analyzed from the finished record.

## Stationary Analysis

A stationary consumer opens a finished run — `RUN_COMPLETE`, or
`RUN_ABORTED` for a record truncated at the abort but consistent up to it —
and reads a fixed record. Three views of the same record serve different
questions.

**The delivered series.** Concatenate the ground batches on the payload
grid: batch rows from `payload_row` (`masks/batch_epochs.csv` tabulates
`Batch, GenSimTime, ContentEpoch, PayloadRow` for every generated batch),
samples from the segment files, and `missing` wherever no delivered batch
covers a row. The holes carry a cause, and post-processing writes them as
`masks/gaps.csv` — one row per hole, `Cause, Batch, RowFirst, RowLast,
ContentStart, ContentEnd`, the content interval `[ContentStart,
ContentEnd)`, sorted by `RowFirst`; the rows of the table and the rows no
delivered batch covers are the same set. The causes and where the record
declares each:

| Hole | Where it is declared | Rows |
|---|---|---|
| lost batch | `events_rx.csv` row `lost`; the batch in `lost/` with its metadata | its `payload_row … + points_per_batch − 1` |
| pruned payload | `events_rx.csv` row `pruned`; the `PRUNED` marker in `ground/<BATCH>/` | the same |
| generation gap | `gap_start` / `gap_end` pair in `events_tx.csv` (`STREAM`, `SCHEDULED`, `RECORDER`) | the rows between the two instants |
| undelivered at run end | a `gen` row in `events_tx.csv` with no `ingested` or `lost` row; the batch directory under `onboard/` or `link/` | its `payload_row … + points_per_batch − 1` |
| not generated by run end | no `gen` row: the mission ended before the payload was exhausted | the rows past the last generated batch, up to `external_data_rows` |
| beyond the record | `external_data_rows` in `[provenance]` (external payload) | every row past it holds the producer's zero padding |

A gap-aware statistic takes the holes as declared intervals rather than
inferring them from the spacing of the delivered samples: the spacing cannot
tell a lost batch from an undelivered one, and cannot see a gap before the
first or after the last delivered sample.

```julia
using DeepSpaceTelemetry: TelemetryCore
using Dates, DataFrames

run_dir = TelemetryCore.run_directory("RUN_ID")
cfg = TelemetryCore.load_run_config(run_dir)
phys = cfg["physics"]
points_per_batch = round(Int, phys["sample_rate"] * phys["segment_duration_sec"]) * phys["batch_size"]

holes = TelemetryCore.read_table(joinpath(run_dir, "masks", "gaps.csv"))
rx = TelemetryCore.read_table(joinpath(run_dir, "events_rx.csv"))
first_row = TelemetryCore.batch_payload_rows(run_dir)      # every generated batch, all stages
delivered = setdiff(Set(rx.Batch[rx.Event .== "ingested"]), Set(rx.Batch[rx.Event .== "pruned"]))

n_rows = max(
    maximum(holes.RowLast; init = 0),
    maximum(first_row[name] + points_per_batch - 1 for name in delivered),
)
series = Vector{Union{Missing,Float32}}(missing, n_rows)
for name in delivered
    payload = read_payload(joinpath(run_dir, "ground", name))   # as in the streaming example
    r = first_row[name]
    series[r:(r + length(payload) - 1)] .= payload
end
```

`series` is the stationary record and `holes` its declared gaps with
causes, each row an interval `RowFirst:RowLast` on the same grid; a
`recorder` hole is the one whose rows were generated and dropped on board
rather than never generated, so its rows sit on the grid like every other.
`Masks.gap_table(run_dir)` computes the same table from the record for a
run made before the product existed; a run older than 2.1.0 has no
`payload_row` stamps and no gap rows, and batch `k` then starts at row
`(k − 1) · points_per_batch + 1`.

**The arrival stream, replayed.** For a latency study, replay
`events_rx.csv` in `SimTime` order as the arrival stream and drive the same
consumer logic as in Streaming Consumption: the event log is the ground
truth from which the framework's own mask products are computed, so the
replayed availability is bit-identical to what a live consumer saw. This is
how a streaming analysis is developed and regression-tested against recorded
runs before it follows a live one, and how two routing rules or two link
models are compared on the same arrival logic.

**The prepared products.** Post-processing derives from the record the
views most analyses want and that need no replay of one's own:

* `masks/telemetry_mask_timeline.csv` — rows = snapshot instants (`SimTime`,
  one per `mission_profile.csv` row), columns `Batch_<k>` for every batch
  identifier up to the largest generated, values `0 = Future`, `1 = Onboard`,
  `2 = Link`, `3 = Ground`, `4 = Lost`. A window anchored at snapshot `r` may
  use exactly the batches with state 3 in row `r`: the live view of a
  streaming consumer at that instant, without running one.
* `masks/pointwise_mask_final.csv` and `masks/pointwise_mask_t<row>.csv` —
  the 0/1 expansion of one snapshot row onto the sample grid (`Time_Index,
  Ground_Available`), from `scripts/postprocessing/apply_telemetry_mask.jl`
  (config-aware) or the dependency-light `standalone_mask_expander.jl`
  (`CSV` and `DataFrames` only, for collaborators on other toolchains);
  multiply an expanded row against the raw series to blank undelivered data.
  Re-anchor the rows through `masks/batch_epochs.csv` when gap events are
  present.
* `masks/gaps.csv` — the holes of the delivered record with their causes,
  as above; `masks/batch_epochs.csv` — the batch → epoch and payload-row
  map.
* `mission_profile.csv` — link capacity, on-board and link buffers, the
  cumulative ground counts, losses and retries at a change-driven cadence;
  `delivery_delay.csv` — the measurement-to-ground delay of every generated
  batch, `missing` for the undelivered; `alert_latency.csv` and
  `alert_latency_markers.csv` — the completion of the look-back window after
  a live event, realized against the FIFO counterfactual, and at every
  marker; `markers.csv` — the event markers.
* `products.h5` — all of the above in one file (HDF5 Product Export below).

**Reproducibility.** `config_snapshot.toml` (the parameters, the commit,
the platform) and `manifest_snapshot.toml` fix the code and the environment
of a run; the seeded scenario fixes the loss draws. A tick-mode run
(`clock_anchor.toml` with `mode = "tick"`) is then reproducible to the
byte on one platform: its event logs, mask timeline, batch epochs, and
metrics profile apart from the wall-clock column. A wall-mode run is not:
its components are paced against wall time, so a rerun of the same
scenario on another machine delivers the same regimes with different
counts to the last batch, and a stationary study across wall runs
compares regimes, distributions, and declared products rather than raw
counts.

**Consumer archetypes.** A *replay engine* consumes a finished run through
the same adapter as its streaming counterpart, in replay mode. A *batch
inference* runs on the finished record with its holes declared; a training
stage usually wants a gapless record, an inference stage tolerates a gapped
one. A *gap-aware statistic* takes the series and the declared holes and
classifies every quantity that spans a hole as exact, gap-crossing, or
censored. The `holes` of the example above are the input such a consumer
wants in place of gaps inferred from spacing.

## HDF5 Product Export

With `post_processing.hdf5_export = true` (or
`scripts/postprocessing/export_hdf5.jl [RUN_ID]` afterward) the run's
products are written into `products.h5`, one self-describing file for
pipelines that read HDF5 rather than a directory of CSV files. The CSV
products stay in place and remain the primary interface; the file is a
derived view of them and can be regenerated at any time.

| Group | Content |
|---|---|
| root attributes | `format_version`, `run_id`, `start_sim_time`, `speed_up`, `exported_at`, the platform fingerprint of the run snapshot (`hostname`, `package_version`, `git_commit`, `julia_version`, …), `config_snapshot` — the run's configuration as TOML text — and `config_source` (`snapshot` or `fallback`, the latter when the project `config.toml` stood in for a missing or corrupt snapshot) |
| `events/tx`, `events/rx` | the event logs, one dataset per column |
| `metrics/mission_profile` | the metrics profile, one dataset per column |
| `masks/timeline` | `states` — the batch-state matrix laid out as `states[snapshot, batch]` for C-order readers (h5py, NumPy; Julia reads the transpose), `batch_id`, the snapshot instants (`SimTime`, `SimTime_iso`), and the attributes `state_codes` and `layout` |
| `masks/batch_epochs` | the batch → epoch map, `PayloadRow` included |
| `masks/gaps` | the gap table, every hole of the delivered record with its cause |
| `masks/pointwise/<stem>` | every point-wise expansion, `Ground_Available` as `Int8` per sample |
| `metrology/alert_latency`, `metrology/alert_latency_markers`, `metrology/delivery_delay` | the metrology tables |
| `markers`, `component_events` | the event markers and the component lifecycle record |

Column conventions: a `DateTime` column is stored as `Float64` seconds
since `start_sim_time` (attribute `unit`) with an ISO-8601 twin `<name>_iso`;
booleans as `UInt8` (`0xff` for missing); integers as `Int64` (or `Float64`
with `NaN` when a value is missing); other numbers as `Float64` with `NaN`
for missing; the rest as strings with `""` for missing. Each table group
carries the attributes `source` (the CSV it was read from) and `rows`;
`masks/timeline` carries `source`, `state_codes`, and `layout`, and the
point-wise groups `source`.

## Real-Time Operation

`speed_up = 1.0` is a supported configuration (validation only guards
against *too fast* pacing): the mission clock then advances at wall-clock
rate and consumers experience genuine mission cadence — one segment per
`segment_duration_sec` of real time. Current limitation for long campaigns:
a run executes in a single process with no checkpoint/resume, so multi-year
real-time rehearsals should be planned as bounded campaigns (e.g. a session
or a disruption window at 1×) until run resumption is implemented.
