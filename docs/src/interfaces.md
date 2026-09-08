# Analysis Interfaces

The framework couples to external data-analysis pipelines (sliding-window
searches, matched filters, alert generators) exclusively through the
filesystem. There is no in-memory API to link against: every interface below
is a file contract, so consumers may be written in any language and any number
of analysis instances may operate concurrently on a single telemetry run.

## Design Principles

1. **Consumers are read/copy-only.** Analysis processes must never create,
   modify, move, or delete anything inside a run directory. Data a pipeline
   needs to own is copied out to consumer-managed storage.
2. **Concurrent consumers are safe by construction.** All consumer-facing
   files are either append-only (event logs, metrics) or appear atomically
   and are immutable afterwards (batch directories). No locking protocol
   exists or is needed — provided rule 1 is respected.
3. **The contract is invariant under `speed_up`.** A consumer developed
   against an accelerated run (`speed_up = 3600`) works unchanged against a
   real-time run (`speed_up = 1.0`); only the wall-clock arrival cadence
   differs. Develop fast, rehearse at mission cadence.
4. **`config_snapshot.toml` is the only source of derived quantities.**
   Sample rates, segment/batch geometry, and session parameters are read from
   the run's own snapshot, never from the live `config.toml`.

## The Run-Directory Contract

`data/runs/<RUN_ID>/` contents, from a consumer's perspective:

| Artifact | Writer | Consumer access |
|---|---|---|
| `ground/<BATCH>/` | receiver | **Read/copy.** The delivery surface (see below). |
| `lost/<BATCH>/` | receiver | Read/copy. Retry-exhausted batches, preserved but never ground-available. |
| `events_rx.csv` | receiver (single writer) | **Tail/read.** The authoritative arrival feed. |
| `events_tx.csv` | emitter (single writer) | Tail/read. Generation and transmission milestones. |
| `mission_profile.csv` | receiver | Tail/read. Link and buffer metrics (change-driven cadence). |
| `masks/` | post-processing | Read/copy. Batch-state timeline and point-wise expansions. |
| `config_snapshot.toml` | pipeline (at startup) | Read. Exact run parameters (+ `[provenance]` input identity for external data). |
| `RUN_ACTIVE` / `RUN_COMPLETE` / `RUN_ABORTED` | pipeline | Read. Lifecycle sentinels (see below). |
| `clock_anchor.toml` | pipeline (at mission start) | Read. Persisted mission-clock anchor + absolute deadline; re-attaching components reconstruct the identical clock from it. |
| `component_events.csv` | supervisor (single writer) | Tail/read. Component lifecycle record: `down`, `restart`, `stalled`, `recovered`. |
| `emitter_alive` / `receiver_alive` | components (heartbeats) | Read mtime. Liveness signals, refreshed ≈ 1 s while a component runs. |
| `markers.csv` | pipeline (at mission start) | Read. Event markers of the run (`SimTime, Label`) — the instants the alert-latency metric is evaluated at (`alert_latency_markers.csv`). |
| `delivery_delay.csv` | post-processing | Read. Measurement-to-ground delay of every generated batch, with a `LowLatency` flag for deliveries inside a low-latency period (`plots/delivery_delay.png` renders the distribution against the delivery requirement). |
| `alert_latency.csv` | post-processing | Read. Alert-latency curves — median and quartiles of the ground availability of look-back data after a live event, realized doctrine vs counterfactual FIFO drain (`plots/alert_latency.png` renders it). |
| `products.h5` | post-processing (`hdf5_export`) | Read/copy. Every product above in one HDF5 file with provenance attributes (section below); regenerable from the CSV products. |
| `masks/batch_epochs.csv` | post-processing | Read. Batch → epoch map: `GenSimTime` (finalization instant from the event log) and `ContentEpoch` (first-sample timestamp from the batch metadata); re-anchors point-wise mask rows on the mission timeline across generation gaps. |
| `HALT` | **operator** | **The one sanctioned external write**: `touch HALT` stops both components cleanly at their next iteration; the pipeline consumes the file at lifecycle end. |
| `emitter.log`, `receiver.log` | logger | Read. Human diagnostics; not machine-parsed interfaces. |
| `onboard/`, `link/` | emitter/receiver | **Off-limits.** Internal staging; the emitter counts in-flight batches from the `link/` listing, so a slot frees when the receiver moves a batch out. |

A batch directory contains `metadata.json` and one `seg_<id>.csv` per segment
(single `Amplitude` column). The metadata keys are `batch_id`,
`segment_count`, `content_epoch` — the mission timestamp of the payload's
first sample, i.e. the physical epoch the data belong to — and `created_at`
— the mission instant at which the batch was finalized and became
transmittable (never earlier than the content end, and within one segment
period of it when the host keeps pace with the accelerated clock). Segment
files carry no timestamps; sample `k` of a batch lies at
`content_epoch + (k − 1) / sample_rate`. A batch whose payload holds an
event marker carries the marker labels under the optional `markers` key.
Batches are delivered by an atomic same-filesystem `mv`: a directory visible
under `ground/` is complete, and it is never modified afterwards except by
the retention custodian (below).

## Availability Window & Lifecycle Sentinels

With `[retention]` disabled (the default), nothing is deleted from a run
directory while the simulation is active — delivered payloads persist for the
run's lifetime, and the only deletion path in the framework is the
interactive `scripts/maintenance/cleanup.jl`.

With `retention.enabled = true`, the receiver's custodian bounds the
delivered-payload footprint: **a batch's payload is guaranteed readable for
`retention.grace_hours` of mission time after its `ingested` event** — copy
what your pipeline needs within that window. Beyond it, once the payload
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

## Component Outages & Generation Gaps

The two components run under a supervisor (`[supervision]` in the config):
on a component failure the policy `abort`s the run cleanly, `continue`s
one-sided, or `restart`s the component (bounded attempts). Consumers observe
outages through `component_events.csv` and the heartbeat mtimes. A receiver
outage needs no special handling — it reproduces ground-station-blackout
phenomenology (backlog accumulation, then drain). An **emitter outage is a
genuine generation gap**: the restarted instrument resumes at the *current*
mission time with a fresh noise realization, and the dead window is bounded
by `gap_start`/`gap_end` rows (Batch = `STREAM`) in `events_tx.csv`. The
same row pair bounds a **scheduled generation gap** (a disruption event with
`affects = "generation"`; Batch = `SCHEDULED`) and a **recorder overflow**
(the on-board buffer at `storage.onboard_capacity_days`; Batch =
`RECORDER`, closed when room returns). Because batch IDs stay contiguous
while mission time is not, point-wise mask rows must be re-anchored via
`masks/batch_epochs.csv` when gap events are present; the mask replay
itself treats gap events as state-preserving.

## Event Feeds

`events_rx.csv` — columns `SimTime, Batch, Event, Attempt`:

* `ingested` — the batch reached the ground archive. **Ordering guarantee:**
  the payload is moved into `ground/` *before* this row is appended, so a
  consumer that reads an `ingested` event may open the batch immediately.
* `retry` — a transfer attempt was lost; the batch remains on the link and
  is re-served no earlier than one round-trip light time later, other
  in-flight batches first. `Attempt` counts failed attempts so far.
* `lost` — retry budget exhausted; the batch was moved to `lost/` (also
  before the row is appended) and will never become ground-available.

`events_tx.csv` — columns `SimTime, Batch, Event`, with `gen` (batch
finalized onboard), `tx` (batch placed on the downlink), and `marker`
(`SimTime` = an event-marker instant, `Batch` = the batch holding it,
appended when that batch is finalized; state-preserving).

## Batch Identity → Sample Interval

Batch names are `LIVE_batch_<k>` (generated during a contact — a nominal
pass or a low-latency period) or `ARCH_batch_<k>` (generated in a blind
spot or blackout); `k` is the global
1-based batch index. With

```
points_per_batch = sample_rate × segment_duration_sec × batch_size
```

(all three from `config_snapshot.toml` `[physics]`), batch `k` covers rows

```
[(k − 1) · points_per_batch + 1,  k · points_per_batch]
```

of the underlying time series. This mapping is **row-index exact**: in
external mode the intervals index the input CSV rows one-to-one, and the
point-wise masks are generated on the same convention.

## Live Consumption (streaming analysis)

The recommended loop for an online sliding-window pipeline:

1. Tail `events_rx.csv` (poll or `FileWatching`-style monitoring).
2. On `ingested`: map the batch to its sample interval, add it to a coverage
   structure (interval set), and copy the payload out if the pipeline needs
   it beyond the run's lifetime.
3. Evaluate every analysis window that the updated coverage now fully (or
   acceptably) spans.
4. On `lost`: mark the interval as a **permanent hole** — windows crossing it
   must gap-handle or be discarded, never waited on.

Consumers must tolerate out-of-temporal-order arrival: live data streams FIFO
with priority, while the archived backlog backfills LIFO (newest first), so
coverage grows *backwards in time* from each live front — contiguously behind
it, session by session, with a moving frontier at each blind-spot boundary.
This is the intended behavior for sliding-window alert pipelines: the data
most tightly coupled to a live event arrives first.

## Post-Hoc Replay (offline analysis)

For reproducible offline studies, replay `events_rx.csv` in `SimTime` order
as a simulated arrival stream and drive the same consumer logic — the event
log is the ground truth from which the framework's own mask reconstruction is
computed, so replayed availability is bit-identical to the live view.
Alternatively, consume the prepared products:

* `masks/telemetry_mask_timeline.csv` — rows = time snapshots, columns =
  `Batch_<k>`, values `0=Future, 1=Onboard, 2=Link, 3=Ground, 4=Lost`. A
  window anchored at snapshot `r` may use exactly the batches with state 3 in
  row `r`.
* Point-wise 0/1 expansions via
  `scripts/postprocessing/apply_telemetry_mask.jl` (config-aware) or the
  dependency-light `standalone_mask_expander.jl` (requires only `CSV` and
  `DataFrames`; suitable for Python/MATLAB/C++ collaborators to run
  alongside their own tooling). Multiply an expanded row against the raw
  series to blank undelivered data.

## HDF5 Product Export

With `post_processing.hdf5_export = true` (or
`scripts/postprocessing/export_hdf5.jl [RUN_ID]` afterwards) the run's
products are written into `products.h5`, one self-describing file for
pipelines that read HDF5 rather than a directory of CSV files. The CSV
products stay in place and remain the primary interface; the file is a
derived view of them and can be regenerated at any time.

| Group | Content |
|---|---|
| root attributes | `format_version`, `run_id`, `start_sim_time`, `speed_up`, `exported_at`, the platform fingerprint of the run snapshot (`hostname`, `package_version`, `git_commit`, `julia_version`, …), and `config_snapshot` — the run's configuration as TOML text |
| `events/tx`, `events/rx` | the event logs, one dataset per column |
| `metrics/mission_profile` | the metrics profile, one dataset per column |
| `masks/timeline` | `states` — the batch-state matrix laid out as `states[snapshot, batch]` for C-order readers (h5py, NumPy; Julia reads the transpose), `batch_id`, the snapshot instants, and the state-code attribute |
| `masks/batch_epochs` | the batch → epoch map |
| `masks/pointwise/<stem>` | every point-wise expansion, `Ground_Available` as `Int8` per sample |
| `metrology/alert_latency`, `metrology/alert_latency_markers`, `metrology/delivery_delay` | the metrology tables |
| `markers`, `component_events` | the event markers and the component lifecycle record |

Column conventions: a `DateTime` column is stored as `Float64` seconds
since `start_sim_time` (attribute `unit`) with an ISO-8601 twin `<name>_iso`;
booleans as `UInt8`; integers as `Int64` (or `Float64` with `NaN` when a
value is missing); other numbers as `Float64` with `NaN` for missing; the
rest as strings with `""` for missing. Each table group carries the
attributes `source` (the CSV it was read from) and `rows`.

## Real-Time Operation

`speed_up = 1.0` is a supported configuration (validation only guards
against *too fast* pacing): the mission clock then advances at wall-clock
rate and consumers experience genuine mission cadence — one segment per
`segment_duration_sec` of real time. Current limitation for long campaigns:
a run executes in a single process with no checkpoint/resume, so multi-year
real-time rehearsals should be planned as bounded campaigns (e.g. a session
or a disruption window at 1×) until run resumption is implemented.
