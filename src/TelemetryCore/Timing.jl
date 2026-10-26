# --- Component timing ---

"""
    RECEIVER_POLL_INTERVAL_SEC

Receiver idle-poll and metrics-tick interval [wall-clock s], and the
default polling period of `Supervisor.supervise!`.
"""
const RECEIVER_POLL_INTERVAL_SEC = 0.2

# Bandwidth change [percentage points] that admits a mission_profile.csv row.
const METRICS_BANDWIDTH_HYSTERESIS_PCT = 0.1

"""
    RECEIVER_SLEEP_FLOOR_SEC

Minimum receiver download-slot sleep [s], a property of the OS scheduler
rather than a tunable; [`RECEIVER_SLOT_WARN_MS`](@ref) is the slot below
which the validator warns that it distorts the download rate.
"""
const RECEIVER_SLEEP_FLOOR_SEC = 0.001

"""
    EMITTER_PERIOD_WARN_MS

Emitter wall-clock segment period `segment_duration_sec / speed_up` [ms]
below which [`validate_config`](@ref) warns: at shorter periods the
generation loop cannot keep pace with the accelerated clock and the batch
timestamps desynchronize from mission time.
"""
const EMITTER_PERIOD_WARN_MS = 5.0

"""
    RECEIVER_SLOT_WARN_MS

Receiver wall-clock download slot `nominal_batch_transfer_sec / speed_up`
[ms] below which [`validate_config`](@ref) warns: the
[`RECEIVER_SLEEP_FLOOR_SEC`](@ref) sleep floor then distorts the effective
downlink rate.
"""
const RECEIVER_SLOT_WARN_MS = 2.0

"""
    EMITTER_MAX_SLEEP_SEC

Upper bound on a single emitter pacing sleep [wall-clock s]. The generation
loop wakes at least this often to refresh its heartbeat and to honor the
stop flag, the `HALT` sentinel, and the deadline even when one segment
period is long (real-time rehearsals at low `speed_up`).
"""
const EMITTER_MAX_SLEEP_SEC = 0.5

"""
    EMITTER_LAG_WARN_SEC

Wall-clock duration [s] for which the emitter's content lag must persist
above one segment period before the loop warns that the host cannot keep
pace with the accelerated clock. Startup compilation and transient stalls
are recovered by burst catch-up within this window and never warn.
"""
const EMITTER_LAG_WARN_SEC = 5.0

"""
    HEARTBEAT_INTERVAL_MS

Wall-clock interval between two touches of a component's liveness file
[ms]; the supervisor's watchdog reads the file's modification time.
"""
const HEARTBEAT_INTERVAL_MS = 1000

const MS_PER_HOUR = 3_600_000
const MS_PER_DAY = 86_400_000

"""
    thread_advisory() -> Union{Nothing, String}

Returns an advisory message when the process runs on a single Julia thread,
`nothing` otherwise. The emitter, the receiver, and the supervisor are
cooperative tasks: on one thread any non-yielding stretch in one of them
(compilation warm-up, garbage collection, figure rendering) pauses the
others until it yields. Three threads let each task own one; more bring no
benefit because nothing else in the pipeline is parallel.
"""
function thread_advisory()
    Threads.nthreads() >= 2 && return nothing
    return "[THREADS] Running on a single Julia thread: the emitter, receiver, and " *
           "supervisor share it cooperatively, so compilation warm-up, GC, and figure " *
           "rendering in one component pause the others. Launch with `julia --threads=3` " *
           "(or `auto`) for an independent thread per component."
end
