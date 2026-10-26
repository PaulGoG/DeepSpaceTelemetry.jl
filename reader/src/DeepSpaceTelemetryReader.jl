"""
    DeepSpaceTelemetryReader

The reader half of DeepSpaceTelemetry: `TelemetryCore` (configuration,
run layout, batch and table I/O, provenance, the mission clock) and
`RunAdapter` (the reference consumer of a run directory), without the
figure stack and the HDF5 export. A consumer that only reads run
directories adds this package alone, by URL with `subdir = "reader"`;
DeepSpaceTelemetry depends on it and re-exports both modules. The two
packages are versioned together.
"""
module DeepSpaceTelemetryReader

include("TelemetryCore.jl")
include("RunAdapter.jl")

export TelemetryCore, RunAdapter

end # module DeepSpaceTelemetryReader
