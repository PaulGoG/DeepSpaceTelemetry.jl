# --- Mission clocks ---
"""
    MissionClock

The clock a mission runs on. [`SimulationClock`](@ref) paces mission time
against the wall clock (`simulation.mode = "wall"`); [`TickClock`](@ref)
advances it logically, from one component wakeup to the next
(`simulation.mode = "tick"`). The components read the current instant
through [`get_current_sim_time`](@ref), wait through [`wait_until!`](@ref),
[`wait_until_or_change!`](@ref), and the receiver's idle wait, and stop at
[`horizon_reached`](@ref); the mission's physics is expressed in mission
time and is the same under both.
"""
abstract type MissionClock end

"""
    SimulationClock(start_real_time::DateTime, start_sim_time::DateTime, speed_up::Float64) <: MissionClock

The accelerated mission clock: mission time advances `speed_up` times
faster than wall-clock time from the anchor pair `start_real_time` (the
wall instant of the anchor) and `start_sim_time` (the mission instant at
that anchor). [`get_current_sim_time`](@ref) maps the wall clock to mission
`SimTime`; [`due_wall_time`](@ref) is its inverse.
"""
struct SimulationClock <: MissionClock
    start_real_time::DateTime
    start_sim_time::DateTime
    speed_up::Float64
end

"""
    get_current_sim_time(clock::SimulationClock) -> DateTime

The current mission instant: `start_sim_time` plus `speed_up` times the wall
time elapsed since `start_real_time`, rounded to the millisecond.
"""
function get_current_sim_time(clock::SimulationClock)
    elapsed_real_ms = (now() - clock.start_real_time).value
    sim_ms = elapsed_real_ms * clock.speed_up
    return clock.start_sim_time + Millisecond(round(Int, sim_ms))
end

"""
    due_wall_time(clock::SimulationClock, sim_time::DateTime) -> DateTime

Wall-clock instant at which the mission clock reaches `sim_time` — the
inverse of [`get_current_sim_time`](@ref). Each due time is computed from
the clock anchor and the absolute mission instant, so pacing loops that
sleep until a due time accumulate no rounding across iterations.
"""
function due_wall_time(clock::SimulationClock, sim_time::DateTime)
    sim_ms = (sim_time - clock.start_sim_time).value
    return clock.start_real_time + Millisecond(round(Int, sim_ms / clock.speed_up))
end

"""
    save_clock_anchor(run_dir::String, clock::SimulationClock, deadline::DateTime)

Persists the mission clock anchor (wall epoch, mission epoch, speed-up) and
the absolute wall-clock deadline into `<run_dir>/clock_anchor.toml`,
rotating an existing file to `clock_anchor#k.toml`. Written once at mission
start; a re-attaching or restarted component reconstructs the identical
clock from it ([`load_clock_anchor`](@ref)), so a component outage elapses
as mission time.
"""
function save_clock_anchor(run_dir::String, clock::SimulationClock, deadline::DateTime)
    path = joinpath(run_dir, "clock_anchor.toml")
    backup_existing(path)
    open(path, "w") do io
        TOML.print(
            io,
            Dict(
                "mode" => "wall",
                "wall_epoch" => string(clock.start_real_time),
                "start_sim_time" => string(clock.start_sim_time),
                "speed_up" => clock.speed_up,
                "deadline_wall" => string(deadline),
            ),
        )
    end
end

"""
    load_clock_anchor(run_dir::String) -> NamedTuple

Reconstructs the anchor persisted by [`save_clock_anchor`](@ref):
`(mode, clock, deadline, horizon)` with `mode` `"wall"` (also for anchors
written before the key existed) or `"tick"`, `clock` the
[`SimulationClock`](@ref) or the [`TickClock`](@ref) at its epoch,
`deadline` the absolute wall deadline of a wall run (`nothing` for a tick
run), and `horizon` the mission end of a tick run (`nothing` for a wall
run). Throws an `ArgumentError` when the anchor file is absent (runs
started by an older pipeline cannot be re-attached).
"""
function load_clock_anchor(run_dir::String)
    path = joinpath(run_dir, "clock_anchor.toml")
    isfile(path) || throw(
        ArgumentError(
            "[RUN] clock_anchor.toml missing in $run_dir — component re-attachment requires the persisted anchor written at mission start.",
        ),
    )
    a = TOML.parsefile(path)
    mode = String(get(a, "mode", "wall"))
    if mode == "tick"
        clock = TickClock(
            DateTime(a["start_sim_time"]),
            DateTime(a["horizon_sim"]);
            wall_epoch = DateTime(a["wall_epoch"]),
        )
        return (mode = mode, clock = clock, deadline = nothing, horizon = clock.horizon)
    end
    clock = SimulationClock(
        DateTime(a["wall_epoch"]),
        DateTime(a["start_sim_time"]),
        Float64(a["speed_up"]),
    )
    return (
        mode = mode,
        clock = clock,
        deadline = DateTime(a["deadline_wall"]),
        horizon = nothing,
    )
end

# --- Tick clock ---
"""
    TickWakeup

A parked component of the [`TickClock`](@ref): the mission instant `at` it
asked to resume at, its component `priority` (the emitter before the
receiver at an equal instant), the registration `sequence` breaking the
remaining ties, and the `release` channel the driver signals.
"""
struct TickWakeup
    at::DateTime
    priority::Int
    sequence::Int
    release::Channel{Nothing}
end

"""
    TickClock(start_sim_time::DateTime, horizon::DateTime; wall_epoch = now()) <: MissionClock

The logical mission clock of `simulation.mode = "tick"`. Mission time
advances only while every component task is parked, jumping to the earliest
requested wakeup, so a mission is a deterministic sequence of events for a
given seed and does not wait on the wall clock. `now_sim` is the current
instant, `horizon` the mission end (`start_sim_time + mission_days`), and
`wall_epoch` the wall instant of the start, kept for the anchor only. The
components are created by [`tick_spawn`](@ref), park through
[`wait_until!`](@ref), [`wait_until_or_change!`](@ref), and
[`wait_for_change!`](@ref), and are driven by [`run_ticks!`](@ref) on the
driver's thread.
"""
mutable struct TickClock <: MissionClock
    const start_sim_time::DateTime
    const horizon::DateTime
    const wall_epoch::DateTime
    now_sim::DateTime
    const wakeups::Vector{TickWakeup}
    sequence::Int
    const parked::Channel{Nothing}
end

function TickClock(
    start_sim_time::DateTime,
    horizon::DateTime;
    wall_epoch::DateTime = now(),
)
    horizon > start_sim_time || throw(
        ArgumentError(
            "[CLOCK] The tick horizon $horizon must lie after the mission epoch $start_sim_time.",
        ),
    )
    return TickClock(
        start_sim_time,
        horizon,
        wall_epoch,
        start_sim_time,
        TickWakeup[],
        0,
        Channel{Nothing}(1),
    )
end

"""
    save_clock_anchor(run_dir::String, clock::TickClock)

Persists the anchor of a tick-mode mission into `<run_dir>/clock_anchor.toml`,
rotating an existing file ([`backup_existing`](@ref)): `mode = "tick"`,
`wall_epoch`, the mission epoch `start_sim_time`, and the horizon
`horizon_sim`. A tick run has no wall deadline.
"""
function save_clock_anchor(run_dir::String, clock::TickClock)
    path = joinpath(run_dir, "clock_anchor.toml")
    backup_existing(path)
    open(path, "w") do io
        TOML.print(
            io,
            Dict(
                "mode" => "tick",
                "wall_epoch" => string(clock.wall_epoch),
                "start_sim_time" => string(clock.start_sim_time),
                "horizon_sim" => string(clock.horizon),
            ),
        )
    end
end

"""
    get_current_sim_time(clock::TickClock) -> DateTime

The current logical instant of the tick clock.
"""
get_current_sim_time(clock::TickClock) = clock.now_sim

"""
    horizon_reached(clock::MissionClock) -> Bool

Whether the mission clock has reached its horizon: never for the wall
clock, whose components hold the wall deadline themselves; for the tick
clock, once its instant equals the horizon.
"""
horizon_reached(::SimulationClock) = false
horizon_reached(clock::TickClock) = clock.now_sim >= clock.horizon

"""
    EMITTER_PRIORITY

Wakeup priority of the emitter under the [`TickClock`](@ref): at an equal
instant generation precedes service, as the instrument delivers a segment
after observing it and the ground serves what is on the link.
"""
const EMITTER_PRIORITY = 0

"""
    RECEIVER_PRIORITY

Wakeup priority of the receiver under the [`TickClock`](@ref), after the
emitter ([`EMITTER_PRIORITY`](@ref)).
"""
const RECEIVER_PRIORITY = 1

"""
    park!(clock::TickClock, at::DateTime, priority::Int)

Registers a wakeup of the calling task at `at` with `priority`, tells the
driver the task has parked, and blocks until the driver releases it.
"""
function park!(clock::TickClock, at::DateTime, priority::Int)
    release = Channel{Nothing}(1)
    clock.sequence += 1
    push!(clock.wakeups, TickWakeup(at, priority, clock.sequence, release))
    put!(clock.parked, nothing)
    take!(release)
    return nothing
end

"""
    earliest_wakeup(clock::TickClock) -> DateTime

The earliest instant a parked task asked to resume at, or the horizon when
none is parked.
"""
earliest_wakeup(clock::TickClock) =
    isempty(clock.wakeups) ? clock.horizon : minimum(w.at for w in clock.wakeups)

"""
    wait_until!(clock::MissionClock, sim_time::DateTime; deadline = nothing, floor_sec = 0.0, cap_sec = Inf, priority = 0)

Blocks the calling component until the mission clock reaches `sim_time`.
On the wall clock the wait is a sleep until [`due_wall_time`](@ref) of the
instant, clamped at the wall `deadline` when given, with the sleep length
clamped to `[floor_sec, cap_sec]` wall seconds so the caller's periodic
checks stay responsive (a zero-length sleep yields). On the tick clock the
task parks with a wakeup at `sim_time` (or now, if that is later) and
`priority`, and resumes once the driver has advanced the clock to it; the
keywords of the wall form are ignored.
"""
function wait_until!(
    clock::SimulationClock,
    sim_time::DateTime;
    deadline::Union{DateTime,Nothing} = nothing,
    floor_sec::Float64 = 0.0,
    cap_sec::Float64 = Inf,
    priority::Int = 0,
)
    due = due_wall_time(clock, sim_time)
    deadline !== nothing && (due = min(due, deadline))
    wait_sec = (due - now()).value / 1000.0
    sleep(clamp(wait_sec, floor_sec, cap_sec))
    return nothing
end
function wait_until!(clock::TickClock, sim_time::DateTime; priority::Int = 0, kwargs...)
    return park!(clock, max(sim_time, clock.now_sim), priority)
end

"""
    wait_until_or_change!(clock::MissionClock, sim_time::DateTime; kwargs...)

Like [`wait_until!`](@ref), but a wait that another component's activity
may cut short: on the wall clock the clamped sleep re-polls at `cap_sec` at
the latest; on the tick clock the task resumes at `sim_time` or at the next
wakeup of another component, whichever comes first. The receiver waits this
way for a deferred retransmission, so a batch placed on the link in the
meantime is served without waiting out the round trip.
"""
function wait_until_or_change!(clock::SimulationClock, sim_time::DateTime; kwargs...)
    return wait_until!(clock, sim_time; kwargs...)
end
function wait_until_or_change!(
    clock::TickClock,
    sim_time::DateTime;
    priority::Int = 0,
    kwargs...,
)
    return park!(clock, max(min(sim_time, earliest_wakeup(clock)), clock.now_sim), priority)
end

"""
    wait_for_change!(clock::TickClock; priority = 0)

Parks the calling task until the next wakeup of another component has run
(or the horizon, when none is parked): the receiver's idle wait under the
tick clock, where the link can only change when the emitter runs.
"""
function wait_for_change!(clock::TickClock; priority::Int = 0)
    return park!(clock, max(earliest_wakeup(clock), clock.now_sim), priority)
end

"""
    tick_spawn(clock::TickClock, priority::Int, f) -> Task

Creates the task of a component under the tick clock: `f()` starts when the
driver first releases the task, at the current instant with `priority`, and
the driver is told when the task parks or ends. The task runs on the
driver's thread, so the components interleave only at their waits.
"""
function tick_spawn(clock::TickClock, priority::Int, f)
    release = Channel{Nothing}(1)
    clock.sequence += 1
    push!(clock.wakeups, TickWakeup(clock.now_sim, priority, clock.sequence, release))
    return @async begin
        take!(release)
        try
            f()
        finally
            put!(clock.parked, nothing)
        end
    end
end

"""
    run_ticks!(clock::TickClock, tasks::Dict{Symbol,Task}; on_task_failed = (name, task) -> nothing)

The driver of the tick clock. It advances the clock to the earliest wakeup
(ties broken by component priority, then by registration order), releases
that task, waits until it parks again or ends, and repeats until no task is
parked. The clock stops at the horizon: a later wakeup resumes there, where
the component sees [`horizon_reached`](@ref) and leaves. A task that ended
with an exception is handed to `on_task_failed(name, task)` once; the
callback returns a replacement `Task` created by [`tick_spawn`](@ref),
which takes the name in `tasks`, or `nothing`. Runs on the calling task's
thread.
"""
function run_ticks!(
    clock::TickClock,
    tasks::Dict{Symbol,Task};
    on_task_failed = (name, task) -> nothing,
)
    failed = Set{Symbol}()
    while !isempty(clock.wakeups)
        _, i = findmin(w -> (w.at, w.priority, w.sequence), clock.wakeups)
        wake = clock.wakeups[i]
        deleteat!(clock.wakeups, i)
        clock.now_sim = min(max(clock.now_sim, wake.at), clock.horizon)
        put!(wake.release, nothing)
        take!(clock.parked)
        for (name, task) in collect(tasks)
            (istaskfailed(task) && !(name in failed)) || continue
            push!(failed, name)
            replacement = on_task_failed(name, task)
            if replacement isa Task
                tasks[name] = replacement
                delete!(failed, name)
            end
        end
    end
    return nothing
end
