"""
    DeepSpaceTelemetryReader

The reader half of DeepSpaceTelemetry: `TelemetryCore` (configuration,
run layout, batch and table I/O, provenance, the mission clock) and
`RunAdapter` (typed access to a run directory), without the figure stack
and the HDF5 export. A consumer that only reads run
directories adds this package alone, by URL with `subdir = "reader"`;
DeepSpaceTelemetry depends on it and re-exports both modules. The two
packages are versioned together.
"""
module DeepSpaceTelemetryReader

include("TelemetryCore.jl")
include("RunAdapter.jl")

export TelemetryCore, RunAdapter

using PrecompileTools: @setup_workload, @compile_workload
using Dates: DateTime
using TOML: TOML

# A finished tick run of three batches, one of them lost, with its event logs, hole
# feed and markers, written by the package's own writers; then every read of
# RunAdapter on it.
@setup_workload begin
    @compile_workload begin
        mktempdir() do dir
            Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                origin = DateTime(2035, 1, 1, 6, 0, 0)
                snapshot = Dict{String,Any}(
                    "simulation" => Dict{String,Any}(
                        "mode" => "tick",
                        "mission_days" => 0.01,
                        "initial_downtime_days" => 0.0,
                        "start_sim_time" => "2035-01-01T06:00:00",
                        "rng_seed" => 1,
                    ),
                    "telemetry" => Dict{String,Any}(
                        "session_start" => "06:00:00",
                        "session_duration_hours" => 8.0,
                        "max_batches_per_hour" => 20.0,
                        "bandwidth_profile" => "flat",
                    ),
                    "physics" => Dict{String,Any}(
                        "data_source" => "synthetic",
                        "sample_rate" => 1.0,
                        "segment_duration_sec" => 60.0,
                        "batch_size" => 2,
                    ),
                    "provenance" => Dict{String,Any}(
                        "payload_origin" => "2035-01-01T06:00:00",
                        "platform" => Dict{String,Any}(
                            "package_version" => string(pkgversion(@__MODULE__)),
                        ),
                    ),
                )
                open(joinpath(dir, "config_snapshot.toml"), "w") do io
                    TOML.print(io, snapshot)
                end
                touch(joinpath(dir, "RUN_COMPLETE"))

                # Batch k holds segments 2k − 1 and 2k; its content epoch is
                # 2(k − 1) min and its finalization 2k min after the origin.
                for (k, stage, name) in (
                    (1, "ground", "LIVE_batch_1"),
                    (2, "ground", "ARCH_batch_2"),
                    (3, "lost", "ARCH_batch_3"),
                )
                    segments = [
                        TelemetryCore.DataSegment(
                            2(k - 1) + s,
                            DateTime(2035, 1, 1, 6, 2(k - 1) + s - 1, 0),
                            zeros(Float32, 60),
                        ) for s in 1:2
                    ]
                    created = DateTime(2035, 1, 1, 6, 2k, 0)
                    TelemetryCore.save_batch(
                        joinpath(dir, stage, name),
                        TelemetryCore.DataBatch(k, segments, created);
                        payload_row = 120(k - 1) + 1,
                    )
                    TelemetryCore.log_tx_event(dir, created, name, "gen")
                end

                lost_at = DateTime(2035, 1, 1, 6, 8, 0)
                TelemetryCore.log_rx_event(
                    dir,
                    DateTime(2035, 1, 1, 6, 3, 0),
                    "LIVE_batch_1",
                    "ingested",
                    0,
                )
                TelemetryCore.log_rx_event(
                    dir,
                    DateTime(2035, 1, 1, 6, 5, 0),
                    "ARCH_batch_2",
                    "ingested",
                    0,
                )
                TelemetryCore.log_rx_event(
                    dir,
                    DateTime(2035, 1, 1, 6, 7, 0),
                    "ARCH_batch_3",
                    "retry",
                    1,
                )
                TelemetryCore.log_rx_event(dir, lost_at, "ARCH_batch_3", "lost", 2)
                TelemetryCore.declare_batch_hole!(
                    TelemetryCore.hole_feed(dir),
                    lost_at,
                    "lost",
                    joinpath(dir, "lost", "ARCH_batch_3"),
                )
                TelemetryCore.save_markers(
                    dir,
                    [TelemetryCore.EventMarker(DateTime(2035, 1, 1, 6, 1, 0), "marker 1")];
                    origin = origin,
                    sample_rate = 1.0,
                )

                run = RunAdapter.open_run(dir)
                geometry = RunAdapter.run_geometry(run)
                RunAdapter.run_state(run)
                RunAdapter.record_final(run)
                RunAdapter.run_descriptor(run)
                RunAdapter.list_batches(run)
                RunAdapter.batch_record(run, "LIVE_batch_1")
                RunAdapter.batch_rows(run, "ground", "LIVE_batch_1")
                RunAdapter.read_batch(run, "LIVE_batch_1")
                RunAdapter.read_batch_matrix(run, "LIVE_batch_1"; delivered = true)
                arrivals = RunAdapter.arrival_events(run)
                RunAdapter.arrival_events(RunAdapter.FeedCursor(run, :arrivals))
                RunAdapter.declared_holes(run)
                RunAdapter.declared_holes(RunAdapter.FeedCursor(run, :holes))
                RunAdapter.delivered_rows(run)
                first_ingested =
                    first(e.sim_time for e in arrivals if e.event === :ingested)
                RunAdapter.delivered_rows(run; at = first_ingested)
                RunAdapter.markers(run)
                RunAdapter.label_spans(run)
                RunAdapter.row_time(geometry, 1)
                RunAdapter.time_row(geometry, first_ingested)
            end
        end
    end
end

end # module DeepSpaceTelemetryReader
