using Pkg;
Pkg.activate(joinpath(@__DIR__, ".."), io = devnull);
Pkg.instantiate(io = devnull)
using CSV, DataFrames
using DeepSpaceTelemetry
using DeepSpaceTelemetry: TelemetryCore

sample_rate = 16.0    # [Hz]
duration_hours = 75.0 # Covers 3.125 days of simulation

total_points = round(Int, sample_rate * 3600 * duration_hours)

println("Generating $total_points points of example external strain data...")

# Surrogate inspiral-like waveform: a sinusoid with a linearly growing envelope.
t = range(0, stop = duration_hours * 3600, length = total_points)
amplitude = sin.(2π .* 0.1 .* t) .* (1.0 .+ t ./ 10000.0)

df = DataFrame(Amplitude = amplitude)
out_path = joinpath(@__DIR__, "..", "..", "data", "example_external_strain.csv")
TelemetryCore.safe_csv_write(out_path, df)
println("Saved to $out_path")
