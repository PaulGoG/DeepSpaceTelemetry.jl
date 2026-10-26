# Shared test helpers: a valid configuration stub and a deterministic loss model.

function valid_test_cfg()
    return Dict{String,Any}(
        "simulation" => Dict{String,Any}(
            "speed_up" => 3600.0,
            "mission_wall_seconds" => 10.0,
            "initial_downtime_days" => 0.0,
            "start_sim_time" => "2035-01-01T06:00:00",
            "rng_seed" => 1,
        ),
        "storage" => Dict{String,Any}("max_storage_gb" => 2.0),
        "telemetry" => Dict{String,Any}(
            "session_start" => "08:00:00",
            "session_duration_hours" => 8.0,
            "max_batches_per_hour" => 20.0,
            "bandwidth_profile" => "sine",
        ),
        "physics" => Dict{String,Any}(
            "data_source" => "synthetic",
            "sample_rate" => 4.0,
            "segment_duration_sec" => 60.0,
            "batch_size" => 10,
        ),
    )
end

# The model loses the first attempt served, which under LIVE FIFO order is batch 1.
struct FirstAttemptLoss <: ChannelEffects.LossModel
    failed::Base.RefValue{Bool}
end

function ChannelEffects.sample_loss!(m::FirstAttemptLoss; multiplier::Float64 = 1.0)
    m.failed[] && return false
    m.failed[] = true
    return true
end

"""
    assert_clean_run(run_dir; faults = false)

The run's `supervisor.log` holds no `[Error]` record and, unless `faults`
is set, no `component_events.csv` exists. The post-processing stages log
their failures instead of throwing, so this is the channel that turns a
mission test red.
"""
function assert_clean_run(run_dir::AbstractString; faults::Bool = false)
    log = joinpath(run_dir, "supervisor.log")
    @test isfile(log) && !occursin("[Error]", read(log, String))
    faults || @test !isfile(joinpath(run_dir, "component_events.csv"))
    return nothing
end

"""
    drive_components(clock; emitter, receiver, should_stop) -> Nothing

Runs one emitter and one receiver on the tick driver until the clock's
horizon (or a HALT). `emitter(clock)` and `receiver(clock)` are closures
that call `Emitter.run_emitter` / `Receiver.run_receiver` with their test
keywords; a `nothing` closure skips that component. `should_stop` is
forwarded to `run_ticks!`, which ends a pacing sleep once it holds.
"""
function drive_components(
    clock::TelemetryCore.TickClock;
    emitter = nothing,
    receiver = nothing,
    should_stop = () -> false,
)
    tasks = Dict{Symbol,Task}()
    emitter === nothing || (
        tasks[:emitter] = TelemetryCore.tick_spawn(
            clock,
            TelemetryCore.EMITTER_PRIORITY,
            () -> with_logger(NullLogger()) do
                emitter(clock)
            end,
        )
    )
    receiver === nothing || (
        tasks[:receiver] = TelemetryCore.tick_spawn(
            clock,
            TelemetryCore.RECEIVER_PRIORITY,
            () -> with_logger(NullLogger()) do
                receiver(clock)
            end,
        )
    )
    TelemetryCore.run_ticks!(clock, tasks; should_stop = should_stop)
    for t in values(tasks)
        istaskfailed(t) && wait(t) # rethrow a component failure into the test
    end
    return nothing
end

"""
    ramp_alignment(run_dir, origin, sample_rate) -> NamedTuple

Checks every batch directory of `run_dir` against a ramp payload, the value
of payload row `r` being `r`. A batch is aligned when its `payload_row`
equals `round((content_epoch − origin) · sample_rate) + 1`, its samples in
segment order are the consecutive rows from there, and its segment
identifiers are the consecutive grid positions of those rows. Directories
without a content epoch (foreign or seeded ones) are skipped. Returns the
number of batches checked, the names of the misaligned ones, and the segment
identifiers found more than once.
"""
function ramp_alignment(run_dir::String, origin::DateTime, sample_rate::Float64)
    checked = 0
    misaligned = String[]
    ids = Int[]
    for sub in ("onboard", "link", "ground", "lost")
        dir = joinpath(run_dir, sub)
        isdir(dir) || continue
        for name in readdir(dir)
            batch_dir = joinpath(dir, name)
            isdir(batch_dir) || continue
            meta = TelemetryCore.read_batch_metadata(batch_dir)
            haskey(meta, "content_epoch") || continue
            implied =
                round(
                    Int,
                    (DateTime(meta["content_epoch"]) - origin).value / 1000 * sample_rate,
                ) + 1
            seg_ids = sort!([
                parse(Int, m[1]) for
                m in (match(r"^seg_(\d+)\.csv$", f) for f in readdir(batch_dir)) if
                m !== nothing
            ])
            append!(ids, seg_ids)
            samples = reduce(
                vcat,
                (
                    TelemetryCore.read_table(joinpath(batch_dir, "seg_$(id).csv")).Amplitude
                    for id in seg_ids
                ),
            )
            n = length(samples) ÷ length(seg_ids)
            aligned =
                get(meta, "payload_row", -1) == implied &&
                samples == implied .+ (0:(length(samples)-1)) &&
                seg_ids == (implied - 1) ÷ n + 1 .+ (0:(length(seg_ids)-1))
            aligned || push!(misaligned, name)
            checked += 1
        end
    end
    repeated = [id for id in unique(ids) if count(==(id), ids) > 1]
    return (; checked, misaligned, repeated)
end
