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

struct FirstAttemptLoss <: ChannelEffects.LossModel
    victim::String
    failed::Base.RefValue{Bool}
end

function ChannelEffects.sample_loss!(m::FirstAttemptLoss; multiplier::Float64 = 1.0)
    m.failed[] && return false
    m.failed[] = true
    return true
end
