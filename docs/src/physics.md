# Physics & Queuing Theory

`DeepSpaceTelemetry` mathematically models the challenging telemetry environment of the LISA mission.

## Virtual Instrument (Noise Generation)
In synthetic mode, the simulator generates amplitude-calibrated LISA strain from the analytic one-sided PSD combining:
1. **Optical Metrology System (OMS) Noise**
2. **Test Mass Acceleration Noise**
3. **Galactic Binary Confusion Noise**

Time series are synthesized in the frequency domain (`X_k = z_k √(S(f_k) f_s M/2)` with complex standard-normal `z_k`) on blocks of twice the segment length, shaped with a periodic sqrt-Hann window, and overlap-added at 50%. Because the squared window tiles to unity, the emitted stream is stationary, phase-continuous across segment boundaries, and reproduces `S(f)` at the correct absolute level. Spectral content below `1/(2·segment_duration_sec)` Hz is not representable at this block length — increase the segment duration for low-frequency fidelity.

## Bandwidth Profiling
Satellite-to-ground communication is constrained by Earth's rotation and atmospheric interference. The simulator models the fractional link capacity over an 8-hour window using selectable profiles:
* `sine`: A realistic `sin^2(pi*x)` curve averaging 50% capacity.
* `sigmoid`: Models an abrupt horizon breach with sustained peak capacity.
* `gaussian`: Models a highly directional, narrow-beam pass.
* `flat`: Ideal 100% constant capacity.

## Packet Loss Channel Models
Each batch transfer attempt on the downlink draws one loss realization from the configured `[packet_loss]` model:

* **Bernoulli**: memoryless i.i.d. loss with probability `p_loss` — the textbook baseline.
* **Gilbert–Elliott**: the canonical bursty-channel model. A two-state Markov chain alternates between a GOOD state (loss probability `p_loss_good`) and a BAD state (`p_loss_bad`); transitions occur once per attempt with probabilities `p_good_to_bad` / `p_bad_to_good`. The analytic long-run loss rate `π_bad·p_loss_bad + π_good·p_loss_good` with `π_bad = p_g2b/(p_g2b + p_b2g)` is exposed as `stationary_loss_rate` and validated against the sampled stream in the test suite.

A lost transfer leaves the batch at the head of the link queue (head-of-line blocking, as in real priority downlink protocols) and is retried; after `max_retries` failures the batch moves to `lost/` — data preserved, mask state `4` — and its window slot is acknowledged back to the satellite. `on_loss = "drop"` is shorthand for a zero-retry budget.

## Link-Disruption Events
`[[disruption.events]]` entries superimpose scheduled link catastrophes — solar flares, spacecraft safe-mode entries, ground-station outages — on the daily visibility schedule. During the blackout phase the link capacity is multiplied by `1 − severity`; afterwards it ramps linearly back to nominal over `recovery_hours`. Throughout blackout *and* recovery the stochastic loss probability is scaled by `loss_multiplier` (clamped to `[0,1]`), modeling the noisy, marginal link of a recovering channel. Overlapping events compose conservatively (minimum capacity, maximum loss multiplier).

Because the emitter gates transmission on the *effective* link — geometric visibility × disruption factor — data generated during a blackout is stamped `ARCH_` and accumulates onboard exactly like blind-spot data; the post-event drain then follows the standard LIVE-FIFO/ARCH-LIFO mechanics with no special-case code.

## Queuing Theory: LIFO vs FIFO
LISA accumulates massive data backlogs during its 16-hour blind spots. When the DSN link opens, the satellite routes data using a strict priority system:

1. **Near-Real-Time (Live) Data:** Highest priority. Sent immediately via FIFO to ensure zero latency for ground observatories.
2. **Archive Backfill (LIFO):** Any remaining bandwidth is dedicated to downloading the blind-spot backlog. Crucially, this uses a Last-In, First-Out (LIFO) queue. The newest archived data is transmitted first. This allows Massive Black Hole Binary (MBHB) alert pipelines to continuously stitch the archived inspiral phase backwards from the live merger event without temporal gaps.