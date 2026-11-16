"""
    TelemetryCore

Shared infrastructure of the simulation: configuration loading, schema-aware
validation, storage governance (artifact estimation, budgets, retention
settings), the mission clock and its persisted anchor, run
provenance (event logs, snapshots, `safesave` rotation), and batch/segment
I/O. Routing is implemented in `Emitter` and `Receiver`. The source is
split by concern into the files of `src/TelemetryCore/`.
"""
module TelemetryCore

using CSV: CSV
using DataFrames: DataFrames, DataFrame, names
using Dates: Dates, Date, DateTime, Day, Millisecond, Second, Time, now
using JSON: JSON
using InteractiveUtils: InteractiveUtils
using LinearAlgebra: LinearAlgebra
using SHA: SHA, sha256
using TOML: TOML

include("TelemetryCore/Layout.jl")
include("TelemetryCore/Config.jl")
include("TelemetryCore/Validation.jl")
include("TelemetryCore/Timing.jl")
include("TelemetryCore/Storage.jl")
include("TelemetryCore/Clocks.jl")
include("TelemetryCore/EventLogs.jl")
include("TelemetryCore/HoleFeed.jl")
include("TelemetryCore/TableIO.jl")
include("TelemetryCore/Provenance.jl")
include("TelemetryCore/BatchIO.jl")
include("TelemetryCore/Visibility.jl")

end # module TelemetryCore
