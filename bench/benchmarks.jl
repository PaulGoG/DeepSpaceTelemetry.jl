include(joinpath(@__DIR__, "activate.jl"))
using BenchmarkTools
using Dates, Random, CSV, DataFrames, Logging
using DeepSpaceTelemetry

const suite = BenchmarkGroup()

# Payload generation at the shipped segment geometry (4 Hz, 60 s)
suite["physics"] = BenchmarkGroup()
vi = DeepSpaceTelemetry.VirtualInstrument.InstrumentState(
    DateTime(2035, 1, 1),
    4.0,
    60.0,
    "synthetic",
    "",
)
suite["physics"]["next_segment"] =
    @benchmarkable DeepSpaceTelemetry.VirtualInstrument.next_segment!($vi)

# Batch I/O at the shipped batch geometry (10 segments of 240 samples): the
# per-batch cost that bounds the emitter's pace. Directory creation and
# fixture construction live in the setup phase so the measured region is
# exactly the save + load I/O.
suite["io"] = BenchmarkGroup()
suite["io"]["batch_save_load"] = @benchmarkable begin
    DeepSpaceTelemetry.TelemetryCore.save_batch(path, batch)
    DeepSpaceTelemetry.TelemetryCore.load_segment(joinpath(path, "seg_1.csv"))
end setup = (
    tmp = mktempdir();
    path = joinpath(tmp, "batch_1");
    segments = [
        DeepSpaceTelemetry.TelemetryCore.DataSegment(
            k,
            Dates.DateTime(2035, 1, 1) + Dates.Second(60 * (k - 1)),
            zeros(Float32, 240),
        ) for k in 1:10
    ];
    batch = DeepSpaceTelemetry.TelemetryCore.DataBatch(
        1,
        segments,
        Dates.DateTime(2035, 1, 1),
    )
) teardown = (rm(tmp; recursive = true, force = true))

# Benchmark Channel Effects (hot path: one draw / factor per transfer attempt
# or loop tick — must stay in the ns regime)
suite["channel"] = BenchmarkGroup()
bernoulli = DeepSpaceTelemetry.ChannelEffects.BernoulliLoss(0.1, Xoshiro(1))
gilbert_elliott = DeepSpaceTelemetry.ChannelEffects.GilbertElliottLoss(
    0.02,
    0.3,
    0.005,
    0.4,
    false,
    Xoshiro(2),
)
suite["channel"]["bernoulli_sample"] =
    @benchmarkable DeepSpaceTelemetry.ChannelEffects.sample_loss!($bernoulli)
suite["channel"]["gilbert_elliott_sample"] =
    @benchmarkable DeepSpaceTelemetry.ChannelEffects.sample_loss!($gilbert_elliott)

disruption_cfg = Dict{String,Any}(
    "disruption" => Dict{String,Any}(
        "events" => [
            Dict{String,Any}(
                "start_day" => 2.0,
                "duration_hours" => 60.0,
                "recovery_hours" => 12.0,
                "severity" => 1.0,
                "loss_multiplier" => 8.0,
            ),
            Dict{String,Any}(
                "start_day" => 9.0,
                "duration_hours" => 24.0,
                "recovery_hours" => 6.0,
                "severity" => 0.5,
                "loss_multiplier" => 3.0,
            ),
        ],
    ),
)
timeline = DeepSpaceTelemetry.ChannelEffects.build_disruption_timeline(
    disruption_cfg,
    DateTime(2035, 1, 1),
)
visibility = DeepSpaceTelemetry.TelemetryCore.VisibilityModel(
    Dates.Time(8, 0, 0),
    Dates.Second(8 * 3600),
    "sine",
)
link = DeepSpaceTelemetry.ChannelEffects.LinkModel(visibility, timeline)
t_blackout = DateTime(2035, 1, 3, 12, 0, 0)
suite["channel"]["disruption_factor"] =
    @benchmarkable DeepSpaceTelemetry.ChannelEffects.disruption_factor(
        $timeline,
        $t_blackout,
    )
suite["channel"]["effective_bandwidth"] =
    @benchmarkable DeepSpaceTelemetry.ChannelEffects.effective_bandwidth($link, $t_blackout)

# Benchmark Post-Processing (exact event-log reconstruction at showcase scale:
# ~1500 batches through gen/tx/ingest against 2000 profile rows)
bench_dir = mktempdir()
const bench_profile = let n_batches = 1500, n_rows = 2000
    t0 = DateTime(2035, 1, 1)
    names_ = ["$(isodd(i) ? "LIVE" : "ARCH")_batch_$i" for i in 1:n_batches]
    tx = DataFrame(
        SimTime = repeat([t0], 2n_batches),
        Batch = repeat(names_, 2),
        Event = vcat(fill("gen", n_batches), fill("tx", n_batches)),
    )
    tx.SimTime = vcat(
        [t0 + Minute(i) for i in 1:n_batches],
        [t0 + Minute(n_batches + 2i) for i in 1:n_batches],
    )
    rx = DataFrame(
        SimTime = [t0 + Minute(n_batches + 2i) + Second(30) for i in 1:n_batches],
        Batch = names_,
        Event = fill("ingested", n_batches),
        Attempt = zeros(Int, n_batches),
    )
    CSV.write(joinpath(bench_dir, "events_tx.csv"), sort(tx, :SimTime))
    CSV.write(joinpath(bench_dir, "events_rx.csv"), rx)
    DataFrame(SimTime = [t0 + Minute(3i) for i in 1:n_rows])
end
suite["postproc"] = BenchmarkGroup()
suite["postproc"]["exact_reconstruction"] =
    @benchmarkable DeepSpaceTelemetry.Receiver.reconstruct_batch_states(
        $bench_dir,
        $bench_profile,
    ) samples = 10 evals = 1

# Run benchmarks only when invoked as a script (suppress @info chatter from
# the benchmarked functions; BenchmarkTools progress stays visible). The
# fixture directory is removed even when the run throws.
if abspath(PROGRAM_FILE) == @__FILE__
    println("Running benchmarks...")
    try
        results = with_logger(NullLogger()) do
            run(suite, verbose = true)
        end
        display(results)
        println()
    finally
        rm(bench_dir; recursive = true, force = true)
    end
end
