# --- Mission clocks ---
"""
    MissionClock

The clock a mission runs on, with one subtype, [`TickClock`](@ref). The
components read the current instant through [`get_current_sim_time`](@ref),
wait through [`wait_until!`](@ref), [`wait_until_or_change!`](@ref), and
[`wait_for_change!`](@ref), and stop at [`horizon_reached`](@ref).
"""
abstract type MissionClock end

"""
    load_clock_anchor(run_dir::String) -> NamedTuple

Reads the anchor persisted by [`save_clock_anchor`](@ref) as
`(mode, start_sim_time, wall_epoch, horizon, speed_up, deadline_wall)`:
`mode` is `"wall"` (also for anchors written before the key existed) or
`"tick"`; `start_sim_time` and `wall_epoch` are the mission and wall
instants of the start; `horizon` is the mission end `horizon_sim`, or
`nothing` when the file has none (the anchors of wall runs made before
2.8.0 carry no horizon); `speed_up` is the pace of a wall run (`NaN` when
absent); and `deadline_wall` is the nominal wall end of a wall run
(`nothing` when absent). Throws an `ArgumentError` when the anchor file is
absent.
"""
function load_clock_anchor(run_dir::String)
    path = joinpath(run_dir, "clock_anchor.toml")
    isfile(path) || throw(
        ArgumentError(
            "[RUN] clock_anchor.toml missing in $run_dir: it is written at mission start.",
        ),
    )
    a = TOML.parsefile(path)
    horizon = get(a, "horizon_sim", nothing)
    deadline = get(a, "deadline_wall", nothing)
    return (
        mode = String(get(a, "mode", "wall")),
        start_sim_time = DateTime(a["start_sim_time"]),
        wall_epoch = DateTime(a["wall_epoch"]),
        horizon = horizon === nothing ? nothing : DateTime(horizon),
        speed_up = Float64(get(a, "speed_up", NaN)),
        deadline_wall = deadline === nothing ? nothing : DateTime(deadline),
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
    TickClock(start_sim_time::DateTime, horizon::DateTime;
              wall_epoch = now(), pace = nothing) <: MissionClock

The mission clock. Mission time advances only while every component task
is parked, jumping to the earliest requested wakeup, so a mission is a
deterministic sequence of events for a given seed. `now_sim` is the current
instant, `horizon` the mission end (`start_sim_time` plus
[`mission_span_days`](@ref)), and `wall_epoch` the wall instant of the
start. `pace` (> 0, stored as `Float64`) is the speed-up of a paced run
(`simulation.mode = "wall"`) and `nothing` for an unpaced one (`--tick`).
[`run_ticks!`](@ref) states the pacing rule and drives the components that
[`tick_spawn`](@ref) creates.
"""
mutable struct TickClock <: MissionClock
    const start_sim_time::DateTime
    const horizon::DateTime
    const wall_epoch::DateTime
    const pace::Union{Nothing,Float64}
    now_sim::DateTime
    const wakeups::Vector{TickWakeup}
    sequence::Int
    const parked::Channel{Nothing}
end

function TickClock(
    start_sim_time::DateTime,
    horizon::DateTime;
    wall_epoch::DateTime = now(),
    pace::Union{Nothing,Real} = nothing,
)
    horizon > start_sim_time || throw(
        ArgumentError(
            "[CLOCK] The tick horizon $horizon must lie after the mission epoch $start_sim_time.",
        ),
    )
    pace === nothing ||
        pace > 0 ||
        throw(ArgumentError("[CLOCK] pace must be > 0 (got $pace)."))
    return TickClock(
        start_sim_time,
        horizon,
        wall_epoch,
        pace === nothing ? nothing : Float64(pace),
        start_sim_time,
        TickWakeup[],
        0,
        Channel{Nothing}(1),
    )
end

"""
    save_clock_anchor(run_dir::String, clock::TickClock)

Persists the anchor of a mission into `<run_dir>/clock_anchor.toml`,
rotating an existing file ([`backup_existing`](@ref)): `mode` (`"wall"`
for a paced clock, `"tick"` otherwise), `wall_epoch`, the mission epoch
`start_sim_time`, and the horizon `horizon_sim`; a paced clock adds
`speed_up` (its pace) and `deadline_wall`, the nominal wall instant of the
horizon. Written once at mission start and read back by
[`load_clock_anchor`](@ref).
"""
function save_clock_anchor(run_dir::String, clock::TickClock)
    path = joinpath(run_dir, "clock_anchor.toml")
    backup_existing(path)
    pace = clock.pace
    anchor = Dict{String,Any}(
        "mode" => pace === nothing ? "tick" : "wall",
        "wall_epoch" => string(clock.wall_epoch),
        "start_sim_time" => string(clock.start_sim_time),
        "horizon_sim" => string(clock.horizon),
    )
    if pace !== nothing
        span_ms = (clock.horizon - clock.start_sim_time).value
        anchor["speed_up"] = pace
        anchor["deadline_wall"] =
            string(clock.wall_epoch + Millisecond(round(Int, span_ms / pace)))
    end
    open(path, "w") do io
        TOML.print(io, anchor)
    end
end

"""
    get_current_sim_time(clock::TickClock) -> DateTime

The current logical instant of the tick clock.
"""
get_current_sim_time(clock::TickClock) = clock.now_sim

"""
    horizon_reached(clock::TickClock) -> Bool

Whether the clock's instant has reached its horizon.
"""
horizon_reached(clock::TickClock) = clock.now_sim >= clock.horizon

"""
    loop_should_stop(clock::TickClock, stop, halt_path::String, tag::String) -> Bool

The exit test of a component loop: the cooperative `stop` flag raised
(`nothing` for none), the `HALT` sentinel at `halt_path` present, or the
horizon reached ([`horizon_reached`](@ref)); the cause is logged under
`tag` (e.g. `"[EMITTER]"`).
"""
function loop_should_stop(
    clock::TickClock,
    stop::Union{Threads.Atomic{Bool},Nothing},
    halt_path::String,
    tag::String,
)
    if stop !== nothing && stop[]
        @info "$tag Stop signal received. Shutting down."
    elseif isfile(halt_path)
        @info "$tag HALT sentinel detected. Shutting down."
    elseif horizon_reached(clock)
        @info "$tag Mission horizon reached. Shutting down."
    else
        return false
    end
    return true
end

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
    wait_until!(clock::TickClock, sim_time::DateTime; priority = 0)

Blocks the calling component until the mission clock reaches `sim_time`:
the task parks with a wakeup at `sim_time` (or now, if that is later) and
`priority`, and resumes once the driver has advanced the clock to it.
"""
function wait_until!(clock::TickClock, sim_time::DateTime; priority::Int = 0)
    return park!(clock, max(sim_time, clock.now_sim), priority)
end

"""
    wait_until_or_change!(clock::TickClock, sim_time::DateTime; priority = 0)

Like [`wait_until!`](@ref), but a wait that another component's activity
may cut short: the task resumes at `sim_time` or at the next wakeup of
another component, whichever comes first. The receiver waits this way for
a deferred retransmission, so a batch placed on the link in the meantime is
served without waiting out the round trip.
"""
function wait_until_or_change!(clock::TickClock, sim_time::DateTime; priority::Int = 0)
    return park!(clock, max(min(sim_time, earliest_wakeup(clock)), clock.now_sim), priority)
end

"""
    wait_for_change!(clock::TickClock; priority = 0)

Parks the calling task at the next wakeup of another component (or the
horizon, when none is parked). The task resumes after that component has
run when its `priority` value is not smaller than the component's. The
receiver's idle wait: the link changes only when the emitter runs.
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
    run_ticks!(clock::TickClock, tasks::Dict{Symbol,Task};
               on_task_failed = (name, task) -> throw(TaskFailedException(task)),
               heartbeats = Dict{Symbol,String}(), should_stop = () -> false)

The driver of the tick clock. It advances the clock to the earliest wakeup
(ties broken by component priority, then by registration order), releases
that task, waits until it parks again or ends, and repeats until no task is
parked. The clock stops at the horizon: a later wakeup resumes there, where
the component sees [`horizon_reached`](@ref) and leaves. A task that ended
with an exception is handed to `on_task_failed(name, task)` once; the
callback returns a replacement `Task` created by [`tick_spawn`](@ref),
which takes the name in `tasks`, or `nothing`. Without a callback the
driver ends with the task's exception. Runs on the calling task's thread.

On a paced clock (`clock.pace` set, `simulation.mode = "wall"`) the driver
sleeps, before each release, until the wall instant
`wall_epoch + (t − start_sim_time) / pace` of the logical instant `t`, in
chunks of at most 0.5 s; a host that lags releases at once and catches up.
`should_stop()` (the `HALT` sentinel or the stop flag) is tested between
chunks and ends the sleep, so the components, which check `HALT` at every
wakeup, exit within 0.5 s. An unpaced clock never sleeps.

`heartbeats` maps component names to liveness files. The driver touches
every file at the start, then at most once per
[`HEARTBEAT_INTERVAL_MS`](@ref), after a release or between sleep chunks,
and removes them when it returns normally.
"""
function run_ticks!(
    clock::TickClock,
    tasks::Dict{Symbol,Task};
    on_task_failed = (name, task) -> throw(TaskFailedException(task)),
    heartbeats::AbstractDict{Symbol,String} = Dict{Symbol,String}(),
    should_stop = () -> false,
)
    pace = clock.pace
    foreach(touch, values(heartbeats))
    last_touch = now()
    # Liveness files refreshed at most once per interval, during a pacing
    # sleep as well as after a release.
    function beat!()
        isempty(heartbeats) && return nothing
        (now() - last_touch).value >= HEARTBEAT_INTERVAL_MS || return nothing
        foreach(touch, values(heartbeats))
        last_touch = now()
        return nothing
    end
    failed = Set{Symbol}()
    while !isempty(clock.wakeups)
        _, i = findmin(w -> (w.at, w.priority, w.sequence), clock.wakeups)
        wake = clock.wakeups[i]
        deleteat!(clock.wakeups, i)
        clock.now_sim = min(max(clock.now_sim, wake.at), clock.horizon)
        if pace !== nothing
            # Due instant of the released (horizon-clamped) logical instant.
            elapsed_ms = (clock.now_sim - clock.start_sim_time).value
            due = clock.wall_epoch + Millisecond(round(Int, elapsed_ms / pace))
            while !should_stop()
                remaining = (due - now()).value / 1000
                remaining > 0 || break
                sleep(min(remaining, 0.5))
                beat!()
            end
        end
        put!(wake.release, nothing)
        take!(clock.parked)
        beat!()
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
    foreach(path -> rm(path; force = true), values(heartbeats))
    return nothing
end
