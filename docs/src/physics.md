# Physics & Queuing Theory

`DeepSpaceTelemetry` models the telemetry environment of a deep-space science mission: a duty-cycled ground-station contact, a physical downlink with stochastic loss and scheduled disruptions, and the routing doctrine that decides which data reach the ground first. The telemetry, channel, and queuing layers are mission-agnostic; the shipped scenario and the synthetic payload model the LISA mission.

## Virtual Instrument (Noise Generation)
In synthetic mode, the simulator generates amplitude-calibrated LISA strain from the analytic one-sided PSD combining:
1. **Optical Metrology System (OMS) Noise**
2. **Test Mass Acceleration Noise**
3. **Galactic Binary Confusion Noise**

Time series are synthesized in the frequency domain (`X_k = z_k √(S(f_k) f_s M/2)` with complex standard-normal `z_k`) on blocks of twice the segment length, shaped with a periodic sqrt-Hann window, and overlap-added at 50%. Because the squared window tiles to unity, the emitted stream is stationary, phase-continuous across segment boundaries, and reproduces `S(f)` at the correct absolute level. Spectral content below `1/(2·segment_duration_sec)` Hz is not representable at this block length — increase the segment duration for low-frequency fidelity.

## Bandwidth Profiling
Satellite-to-ground communication is constrained by the ground station's line of sight. The daily contact window opens at `telemetry.session_start` for `telemetry.session_duration_hours` (sessions crossing midnight are handled); outside it the capacity is zero, and within it the fractional capacity follows a selectable profile of the window progress `x ∈ [0, 1]`:
* `sine`: `sin²(πx)` — zero at both horizons, full capacity at culmination, 50 % on average.
* `sigmoid`: `[tanh(kx) + tanh(k(1 − x))] / 2` with `k = telemetry.sigmoid_steepness` — a fast horizon breach to sustained peak capacity. The logistic edges are centred on the window boundaries, so the capacity at the exact session edges is ≈ 0.5 rather than 0 (a documented, test-pinned property; the profile models an abrupt acquisition, not a rise from zero).
* `gaussian`: `exp(−(x − ½)² / 2σ²)` with `σ = telemetry.gaussian_sigma` — a narrow-beam pass.
* `flat`: constant full capacity throughout the window.

## Packet Loss Channel Models
Each batch transfer attempt on the downlink draws one loss realization from the configured `[packet_loss]` model:

* **Bernoulli**: memoryless i.i.d. loss with probability `p_loss` — the textbook baseline.
* **Gilbert–Elliott**: the canonical bursty-channel model. A two-state Markov chain alternates between a GOOD state (loss probability `p_loss_good`) and a BAD state (`p_loss_bad`); transitions occur once per attempt with probabilities `p_good_to_bad` / `p_bad_to_good`. The analytic long-run loss rate `π_bad·p_loss_bad + π_good·p_loss_good` with `π_bad = p_g2b/(p_g2b + p_b2g)` is exposed as `stationary_loss_rate` and validated against the sampled stream in the test suite.

A lost transfer leaves the batch at the head of the link queue (head-of-line blocking, as in real priority downlink protocols) and is retried; after `max_retries` failures the batch moves to `lost/` — data preserved, mask state `4` — which frees its in-flight slot on the link. `on_loss = "drop"` is shorthand for a zero-retry budget.

## Link-Disruption Events
`[[disruption.events]]` entries superimpose scheduled link-degrading events — solar flares, spacecraft safe-mode entries, ground-station outages — on the daily visibility schedule. During the blackout phase the link capacity is multiplied by `1 − severity`; afterwards it ramps linearly back to nominal over `recovery_hours`. Throughout blackout *and* recovery the stochastic loss probability is scaled by `loss_multiplier` (clamped to `[0,1]`), modeling the noisy, marginal link of a recovering channel. Overlapping events compose conservatively (minimum capacity, maximum loss multiplier).

Because the emitter gates transmission on the *effective* link — geometric visibility × disruption factor — data generated during a blackout is stamped `ARCH_` and accumulates onboard exactly like blind-spot data; the post-event drain then follows the standard LIVE-FIFO/ARCH-LIFO mechanics with no special-case code.

## Queuing Theory: LIFO vs FIFO
Between contacts the spacecraft accumulates a backlog (in the shipped LISA scenario, 16 blind hours per day). When the link opens, the satellite routes data under a strict priority doctrine:

1. **Near-real-time (live) data:** highest priority, sent first-in, first-out (FIFO) so the ground sees the newest observations with the smallest latency.
2. **Archive backfill (LIFO):** the remaining bandwidth drains the backlog last-in, first-out — the newest archived data first. For a transient caught live (in the LISA case a massive black-hole binary merger), the archived data immediately preceding it are the most valuable, and LIFO delivery lets alert pipelines extend the waveform backwards from the live event without a gap.