# Scenario library

Every file in this directory is a complete configuration, runnable by path
from the package root:

```bash
julia --threads=3 scripts/run_full_sim.jl <RUN_ID> scenarios/<file>.toml
```

`config.toml` at the package root is the default entry point and is a copy
of `recovery_12h_seasonal.toml`. Each run archives the configuration it used
as `config_snapshot.toml`, so provenance never depends on this directory.
The test suite validates every file here and runs `smoke_1d.toml` end to
end. Safe intervals are documented per key inside each file; the scenario
rationale is stated below and in the manual's usage page.

## Coverage

Unless stated otherwise a scenario uses the physical link (230 kbit/s
downlink against 75 kbit/s production, a flat profile within the pass, 8 h
daily passes starting 08:00, a 50 × 10⁶ km range), 600 s batches of
the synthetic flag series (4 Hz, 60 s segments, 10 per batch: 144 batches per day),
and a 14-day on-board recorder. GE denotes the Gilbert–Elliott bursty
channel with the shipped parameters (stationary loss 6.25 %). Wall times
are at the configured acceleration, before post-processing (about half a
minute per mission day).

| File | Mission | Wall | Capacity, profile | Contacts | Channel | Disruptions, markers | Expected regime |
|---|---|---|---|---|---|---|---|
| `smoke_1d.toml` | 0.5 d | 12 s | physical, flat | 8 h | Bernoulli 1 % | none | one pass drains a 6 h backlog; suite smoke run |
| `nominal_8h.toml` | 7 d | 168 s | physical, flat | 8 h, January | Bernoulli 1 % | none, no backlog | balance: 145.7 delivered against 144 produced per day, the buffer clears at the end of each pass |
| `stress_8h_bursty.toml` | 7 d | 168 s | physical, flat | 8 h, January | GE | solar flare day 2.5, repointing day 1.5, DSN outage day 5, marker day 4 with a triggered low-latency period; 2-day backlog | growth: 138 delivered against 144 produced per day plus the disruption debt; the buffer doubles from 300 to about 600 batches and the 24 h compliance fraction falls to about 55 %; live priority keeps the live alert latency bounded |
| `recovery_12h_seasonal.toml` | 7 d | 168 s | physical, flat | 8 h + 4 h seasonal, 21 June | GE | as the stress scenario, marker 25 June; 2-day backlog | recovery: about 190 batches per 12 h pass against 144 produced per day; the flare and the outage each cost about one pass, so the week ends with the backlog near its initial level (buffer between 120 and 300 batches) where the 8 h stress case doubles it |
| `abstraction_gaussian_peak.toml` | 7 d | 168 s | 60 batches/h peak, Gaussian σ = 0.15 | 8 h, January | GE | as the stress scenario | the pre-library default: a peak abstraction with a 0.38 mean factor, 169 delivered per day, slow drain of the 2-day backlog |
| `backlog_recovery_sine.toml` | 7 d | 168 s | 60 batches/h peak, sine | 8 h, January | Bernoulli 10 % | none; 3-day backlog | backlog recovery over the week under retransmission load (the presentation scenario) |
| `drop_policy.toml` | 3 d | 72 s | physical, flat | 8 h, January | Bernoulli 20 %, drop on loss | partial DSN outage day 1.5; 0.5-day backlog | about one fifth of the transfers lost for good (mask state 4), no retransmission traffic |
| `explicit_schedule.toml` | 7 d | 168 s | physical, flat | explicit pass list: day 2 shortened to 6 h, day 3 missed, day 5 extended to 12 h | GE | repointing day 1.5; 1-day backlog | planned schedules with exceptions; the missed pass produces a two-day gap |
| `long_30d_seasonal.toml` | 30 d | 360 s at 7200× | physical, flat | 8 h + 4 h seasonal from 1 March; passes missed on 9 and 10 March, shortened on 12 March, a 12-day gap 16–27 March | GE | repointing days 2.5 and 20.5, solar flare day 4, 36 h safe mode day 8 (generation), DSN outage day 27; markers 6 and 20 March with triggered periods; 3-day backlog | long horizon: the recorder ceiling is reached inside the contact gap (validation warns; RECORDER rows), the marker inside the gap opens a low-latency period, three passes drain part of the backlog at the end |
| `long_segments_2400s.toml` | 7 d | 168 s | physical, flat | 8 h, January | Bernoulli 1 % | none; 1-day backlog | 2400 s segments at 0.5 Hz, three per 2 h batch: the coarse-batch regime, 12 batches produced per day and 12.3 deliverable |
| `external_ingest.toml` | 2 d | 48 s | physical, flat | 8 h, January | Bernoulli 1 % | none; 0.5-day backlog | ingestion of the generated example series (`scripts/maintenance/generate_example_strain.jl`, 16 Hz, 75 h) through the same pipeline |

The delivered-per-day figures follow from the serial receiver: one batch per
slot of transfer time divided by the profile factor, so a day's capacity is
the link rate times the pass length times the profile mean (flat 1.0, sine
0.5, Gaussian σ = 0.15 0.38), reduced by the retransmission fraction.

## Adding a scenario

Copy the closest file, keep every key with its comment, state the scenario
in the two header lines, and add a row to the table above and to the usage
page. The suite's scenario testset validates the new file automatically.
