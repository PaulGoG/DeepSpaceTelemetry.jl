# --- Component timing ---

# Bandwidth change [percentage points] that admits a mission_profile.csv row.
const METRICS_BANDWIDTH_HYSTERESIS_PCT = 0.1

"""
    HEARTBEAT_INTERVAL_MS

Wall-clock interval [ms] at which the tick driver ([`run_ticks!`](@ref))
refreshes the components' liveness files.
"""
const HEARTBEAT_INTERVAL_MS = 1000

const MS_PER_HOUR = 3_600_000
const MS_PER_DAY = 86_400_000
