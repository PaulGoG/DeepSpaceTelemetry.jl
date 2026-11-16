# Tests of the headless package on its own: its dependency closure, the
# absence of a figure backend, and a mission without figures. The simulator
# itself is tested by the suite of the main package (test/runtests.jl).
include(joinpath(@__DIR__, "activate.jl"))
using Test, TOML
using DeepSpaceTelemetryHeadless
using DeepSpaceTelemetryHeadless: TelemetryCore, Supervisor, Export

# The registered packages of the resolved closure, standard libraries left out.
function registered_closure(manifest_path::AbstractString)
    deps = TOML.parsefile(manifest_path)["deps"]
    return sort!([name for name in keys(deps) if !isdir(joinpath(Sys.STDLIB, name))])
end

@testset "DeepSpaceTelemetryHeadless" begin
    @testset "Dependency closure: every package listed with its licence" begin
        manifest = joinpath(@__DIR__, "Manifest.toml")
        licences = TOML.parsefile(joinpath(@__DIR__, "licences.toml"))["packages"]
        closure = filter(
            n -> !(n in ("DeepSpaceTelemetryHeadless", "DeepSpaceTelemetryReader")),
            registered_closure(manifest),
        )
        # A dependency the list does not name has not had its licence read.
        unlisted = setdiff(closure, keys(licences))
        @test isempty(unlisted)
        @test all(
            in(("MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause")),
            values(licences),
        )
    end

    @testset "No figure backend and no HDF5 export on its own" begin
        @test !Supervisor.figure_backend_loaded()
        @test !Export.hdf5_available()
    end

    @testset "A mission writes its tables and no figure" begin
        mktempdir() do data_root
            cfg = Dict{String,Any}(
                "simulation" => Dict{String,Any}(
                    "mode" => "tick",
                    "mission_days" => 0.5,
                    "initial_downtime_days" => 0.1,
                    "start_sim_time" => "2035-01-01T06:00:00",
                    "rng_seed" => 7,
                ),
                "telemetry" => Dict{String,Any}(
                    "session_start" => "08:00:00",
                    "session_duration_hours" => 8.0,
                    "max_batches_per_hour" => 20.0,
                    "bandwidth_profile" => "flat",
                ),
                "physics" => Dict{String,Any}(
                    "data_source" => "synthetic",
                    "sample_rate" => 1.0,
                    "segment_duration_sec" => 60.0,
                    "batch_size" => 10,
                ),
            )
            run_dir = Supervisor.run_mission(
                cfg;
                run_id = "HEADLESS_SMOKE",
                data_root,
                orig_stdout = devnull,
            )
            @test isfile(joinpath(run_dir, "RUN_COMPLETE"))
            @test isfile(joinpath(run_dir, "delivery_delay.csv"))
            @test isfile(joinpath(run_dir, "masks", "gaps.csv"))
            @test isfile(joinpath(run_dir, "descriptor.toml"))
            plots = joinpath(run_dir, "plots")
            @test !isdir(plots) || isempty(readdir(plots))
        end
    end
end
