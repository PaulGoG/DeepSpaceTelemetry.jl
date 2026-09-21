"""
    VirtualInstrument

Science-payload data source. The synthetic payload is a binary flag series:
`0` on a segment holding noise only, `1` on a segment holding a flagged
signal, the flagged segments being those whose content span holds an event
marker. The alternative source is gapless segmented ingestion of an external
CSV time series.

The telemetry layers never read the payload. The flag series carries what a
downstream consumer needs from it — which delivered samples belong to an
event — and nothing else; a physical noise or waveform model is supplied
through the external source.
"""
module VirtualInstrument

using ..TelemetryCore
using CSV: CSV
using DataFrames: DataFrames, DataFrame
using Dates: Dates, DateTime

"""
    PayloadSource

Origin of the samples of an [`InstrumentState`](@ref). A source implements
`segment_samples!(source, epoch, stop, n_samples) -> Vector{Float32}`, the
samples of the segment with content span `[epoch, stop)`.
"""
abstract type PayloadSource end

"""
    FlaggedSignal(instants::Vector{DateTime})

Synthetic binary payload: a segment is `1` throughout when its content span
`[epoch, stop)` holds one of `instants`, and `0` otherwise. The instants are
the event markers of the scenario, so the series is declared by the
configuration and involves no random draw.
"""
struct FlaggedSignal <: PayloadSource
    instants::Vector{DateTime}
    FlaggedSignal(instants::Vector{DateTime}) = new(sort(instants))
end

"""
    ExternalSeries(samples::Vector{Float32})

Externally supplied time series consumed in consecutive segments from
`index` onwards. Past its end the series is padded with zeros.
"""
mutable struct ExternalSeries <: PayloadSource
    samples::Vector{Float32}
    index::Int
    ExternalSeries(samples::Vector{Float32}) = new(samples, 1)
end

"""
    InstrumentState(start_t, sample_rate, segment_duration_sec, data_source, ext_path; markers = EventMarker[])

State of the science payload: the content instant `last_t` of the next
segment, the running segment identifier, the segment geometry, and the
[`PayloadSource`](@ref) the samples come from.

`data_source = "synthetic"` builds a [`FlaggedSignal`](@ref) from the
instants of `markers`; `"external"` reads the CSV at `ext_path` (relative
paths resolve against the project root) into an [`ExternalSeries`](@ref),
taking the column `Amplitude` when present and the first column otherwise.
A missing, unreadable, empty, or non-numeric file is a `[CONFIG]` error.

`segment_duration_sec` must be a whole number of milliseconds
([`TelemetryCore.segment_period`](@ref)) and hold at least one sample.

The struct is named differently from its parent module: an exported struct
sharing the module's name shadows the module binding in downstream `using`
scopes and breaks qualified access (`VirtualInstrument.next_segment!`).
"""
mutable struct InstrumentState{S<:PayloadSource}
    last_t::DateTime
    id_counter::Int
    sample_rate::Float64
    segment_duration_sec::Float64
    source::S
end

function InstrumentState(
    start_t::DateTime,
    sample_rate::Float64,
    segment_duration_sec::Float64,
    data_source::String,
    ext_path::String;
    markers::Vector{TelemetryCore.EventMarker} = TelemetryCore.EventMarker[],
)
    sample_rate > 0 || throw(ArgumentError("sample_rate must be > 0 (got $sample_rate)."))
    TelemetryCore.segment_period(segment_duration_sec)
    samples_per_segment(sample_rate, segment_duration_sec)
    source = if data_source == "external"
        ExternalSeries(read_external_series(ext_path))
    elseif data_source == "synthetic"
        FlaggedSignal([m.time for m in markers])
    else
        throw(
            ArgumentError(
                "data_source must be \"synthetic\" or \"external\" (got \"$data_source\").",
            ),
        )
    end
    return InstrumentState(start_t, 1, sample_rate, segment_duration_sec, source)
end

"""
    samples_per_segment(sample_rate, segment_duration_sec) -> Int

Number of samples in one segment, `sample_rate × segment_duration_sec`
rounded to the nearest integer. `ArgumentError` when the product is below
one: the sample period would exceed the segment.
"""
function samples_per_segment(sample_rate::Real, segment_duration_sec::Real)
    product = sample_rate * segment_duration_sec
    product >= 1 || throw(
        ArgumentError(
            "sample_rate × segment_duration_sec must be ≥ 1 sample per segment (got $product).",
        ),
    )
    return round(Int, product)
end

"""
    read_external_series(ext_path::String) -> Vector{Float32}

The external payload series of the CSV at `ext_path`, relative paths resolved
against the project root as in `validate_config`. Every failure is a
`[CONFIG]` error naming the file.
"""
function read_external_series(ext_path::String)
    resolved =
        isabspath(ext_path) ? ext_path : joinpath(TelemetryCore.PROJECT_ROOT, ext_path)
    isfile(resolved) || TelemetryCore.config_error(
        "[CONFIG] External data source specified but file not found at: $resolved",
    )
    df = try
        CSV.read(resolved, DataFrame)
    catch e
        TelemetryCore.config_error(
            "[CONFIG] Failed to parse external data CSV at $resolved: $(sprint(showerror, e))",
        )
    end
    isempty(df) && TelemetryCore.config_error(
        "[CONFIG] External data CSV at $resolved contains no rows.",
    )
    column = hasproperty(df, :Amplitude) ? df.Amplitude : df[:, 1]
    eltype(column) <: Real || TelemetryCore.config_error(
        "[CONFIG] External data column in $resolved must be numeric with no missing values (got eltype $(eltype(column))).",
    )
    return Vector{Float32}(column)
end

"""
    segment_samples!(source::PayloadSource, epoch, stop, n_samples) -> Vector{Float32}

The `n_samples` samples of the segment with content span `[epoch, stop)`.
An [`ExternalSeries`](@ref) advances its read index; a
[`FlaggedSignal`](@ref) is stateless.
"""
function segment_samples!(
    source::FlaggedSignal,
    epoch::DateTime,
    stop::DateTime,
    n_samples::Int,
)
    first_at_or_after = searchsortedfirst(source.instants, epoch)
    flagged =
        first_at_or_after <= length(source.instants) &&
        source.instants[first_at_or_after] < stop
    return fill(Float32(flagged), n_samples)
end

function segment_samples!(source::ExternalSeries, ::DateTime, ::DateTime, n_samples::Int)
    data = zeros(Float32, n_samples)
    available = length(source.samples) - source.index + 1
    if available < n_samples
        @warn "[INSTRUMENT] External data exhausted at sample $(source.index) of " *
              "$(length(source.samples)): padding with zeros from here on. " *
              "Provide a longer series or shorten the mission." maxlog = 1
    end
    n_copied = clamp(available, 0, n_samples)
    copyto!(data, 1, source.samples, source.index, n_copied)
    source.index += n_samples
    return data
end

"""
    next_segment!(vi::InstrumentState) -> DataSegment

The next segment of science data, stamped with its content epoch; advances
the content clock by one segment period and the segment identifier by one.
"""
function next_segment!(vi::InstrumentState)
    period = TelemetryCore.segment_period(vi.segment_duration_sec)
    n_samples = samples_per_segment(vi.sample_rate, vi.segment_duration_sec)
    data = segment_samples!(vi.source, vi.last_t, vi.last_t + period, n_samples)
    segment = TelemetryCore.DataSegment(vi.id_counter, vi.last_t, data)
    vi.last_t += period
    vi.id_counter += 1
    return segment
end

end # module VirtualInstrument
