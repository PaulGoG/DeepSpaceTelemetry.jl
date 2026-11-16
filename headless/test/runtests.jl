# Tests of the headless package on its own: its dependency closure, the
# absence of a figure backend, and a mission without figures. The simulator
# itself is tested by the suite of the main package (test/runtests.jl).
include(joinpath(@__DIR__, "activate.jl"))
using Test, TOML
using DeepSpaceTelemetryHeadless
using DeepSpaceTelemetryHeadless: TelemetryCore, Supervisor, Export

include("licences.jl")

@testset "DeepSpaceTelemetryHeadless" begin
    @testset "Dependency closure: every package listed with its licence" begin
        # A dependency the list does not name has not had its licence read;
        # the list states what the installed licence files state, and each of
        # those is permissive.
        problems = licence_report(joinpath(@__DIR__, "Manifest.toml"))
        foreach(p -> @info("[LICENCE] $p"), problems)
        @test isempty(problems)
        @test length(registered_closure(joinpath(@__DIR__, "Manifest.toml"))) >= 30
    end

    @testset "Licence classification and its rejections" begin
        mit = "Permission is hereby granted, free of charge, to any person"
        gpl = "GNU General\n   Public License, version 2"   # broken across lines
        package(files...) = mktempdir() do dir
            for (name, text) in files
                write(joinpath(dir, name), text)
            end
            licence_of_directory(dir)
        end
        @test package("LICENSE" => mit) == "MIT"
        @test package("LICENSE" => gpl) == "GPL"
        @test package("LICENSE.md" => mit * "\n" * gpl) == "GPL+MIT"
        @test package("LICENSE.md" => "Apache License", "LICENSE-X.md" => mit) ==
              "Apache-2.0+MIT"
        @test package("COPYING" => "All rights reserved.") == "UNKNOWN"
        @test package("README.md" => mit) == "NONE"
        listed = Dict("A" => "MIT", "B" => "GPL+MIT", "C_jll" => "MIT", "D_jll" => "MIT")
        binaries = Dict("D_jll" => "GPL")
        @test isempty(package_problems("A", "MIT", listed, binaries))
        @test !isempty(package_problems("A", "Apache-2.0", listed, binaries))
        @test !isempty(package_problems("B", "GPL+MIT", listed, binaries))
        @test !isempty(package_problems("Z", "MIT", listed, binaries))
        @test !isempty(package_problems("C_jll", "MIT", listed, binaries))
        @test !isempty(package_problems("D_jll", "MIT", listed, binaries))
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
