# Export: the HDF5 product file.

@testset "HDF5 product export" begin
    HDF5 = DeepSpaceTelemetry.Export.HDF5
    mktempdir() do dir
        t0 = DateTime(2035, 1, 1, 6)
        D = Minute(3)
        open(joinpath(dir, "config_snapshot.toml"), "w") do io
            write(
                io,
                """
                [simulation]
                speed_up = 60.0
                start_sim_time = "2035-01-01T06:00:00"
                mission_wall_seconds = 60.0
                [physics]
                data_source = "synthetic"
                sample_rate = 4.0
                segment_duration_sec = 60.0
                batch_size = 3
                [provenance.platform]
                hostname = "testhost"
                git_commit = "abc123"
                """,
            )
        end
        for (name, epoch) in (("ARCH_batch_1", t0 - D), ("LIVE_batch_2", t0))
            TelemetryCore.log_tx_event(dir, epoch + D, name, "gen")
        end
        TelemetryCore.log_rx_event(dir, t0 + Minute(5), "LIVE_batch_2", "ingested", 0)
        TelemetryCore.save_markers(
            dir,
            [TelemetryCore.EventMarker(t0 + Minute(1), "glitch")],
        )
        mkpath(joinpath(dir, "masks"))
        write(
            joinpath(dir, "mission_profile.csv"),
            "SimTime,WallTime,Mission_Day,Hours_Elapsed,Bandwidth_Pct,Onboard_Buffer,Link_Buffer,Ground_Total,Ground_Live,Ground_Arch,Nominal_Bandwidth_Pct,Lost_Count,Retry_Count,Disruption_Active\n" *
            "2035-01-01T06:00:00,2026-01-01T00:00:00,0.0,0.0,50.0,2,0,0,0,0,50.0,0,0,false\n" *
            "2035-01-01T06:06:00,2026-01-01T00:00:06,0.0,0.1,60.0,1,0,1,1,0,60.0,0,0,true\n",
        )
        write(
            joinpath(dir, "masks", "telemetry_mask_timeline.csv"),
            "SimTime,Batch_1,Batch_2\n2035-01-01T06:00:00,1,1\n2035-01-01T06:06:00,1,3\n",
        )
        write(
            joinpath(dir, "masks", "pointwise_mask_final.csv"),
            "Time_Index,Ground_Available\n1,0\n2,0\n3,1\n",
        )
        path = with_logger(NullLogger()) do
            DeepSpaceTelemetry.Export.export_hdf5(dir)
        end
        @test path == joinpath(dir, "products.h5") && isfile(path)
        HDF5.h5open(path, "r") do f
            @test HDF5.read_attribute(f, "format_version") == "1"
            @test HDF5.read_attribute(f, "run_id") == basename(dir)
            @test HDF5.read_attribute(f, "hostname") == "testhost"
            @test HDF5.read_attribute(f, "git_commit") == "abc123"
            @test HDF5.read_attribute(f, "speed_up") == 60.0
            @test occursin("speed_up = 60.0", HDF5.read_attribute(f, "config_snapshot"))
            @test HDF5.read_attribute(f, "config_source") == "snapshot"
            @test read(f["events/tx/Event"]) == ["gen", "gen"]
            @test read(f["events/tx/SimTime"]) ≈ [0.0, 180.0] rtol = 1e-12
            @test read(f["events/tx/SimTime_iso"]) ==
                  ["2035-01-01T06:00:00", "2035-01-01T06:03:00"]
            @test HDF5.read_attribute(f["events/tx"], "rows") == 2
            @test read(f["events/rx/Attempt"]) == [0]
            @test read(f["markers/Label"]) == ["glitch"]
            @test read(f["metrics/mission_profile/Onboard_Buffer"]) == [2, 1]
            @test read(f["metrics/mission_profile/Disruption_Active"]) == UInt8[0, 1]
            states = read(f["masks/timeline/states"])
            @test size(states) == (2, 2) && states[2, 2] == 3 # Julia reads (batch, snapshot)
            @test read(f["masks/timeline/batch_id"]) == [1, 2]
            @test read(f["masks/timeline/SimTime"]) ≈ [0.0, 360.0] rtol = 1e-12
            @test read(f["masks/pointwise/pointwise_mask_final/Ground_Available"]) ==
                  Int8[0, 0, 1]
            @test !haskey(f, "metrology/delivery_delay")
        end
        with_logger(NullLogger()) do
            DeepSpaceTelemetry.Export.export_hdf5(dir)
        end
        @test isfile(joinpath(dir, "products#1.h5"))
    end
    @test_throws ArgumentError DeepSpaceTelemetry.Export.export_hdf5(
        joinpath(mktempdir(), "absent"),
    )
    cfg = valid_test_cfg()
    cfg["post_processing"] = Dict{String,Any}("hdf5_export" => "yes")
    @test_throws ArgumentError TelemetryCore.validate_config(cfg)
    cfg["post_processing"]["hdf5_export"] = true
    @test TelemetryCore.estimate_artifacts(cfg).hdf5_bytes > 0
    @test TelemetryCore.estimate_artifacts(valid_test_cfg()).hdf5_bytes == 0
    @test !isempty(TelemetryCore.platform_provenance()["package_version"])
end
