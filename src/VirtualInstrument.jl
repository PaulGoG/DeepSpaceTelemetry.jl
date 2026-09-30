"""
    VirtualInstrument

Science-payload data source. The synthetic payload is a binary flag series:
`0` on a segment holding noise only, `1` on a segment holding a flagged
signal, the flagged segments being those whose content span holds an event
marker. The alternative source is an external CSV time series whose row `r`
is the sample at `origin + (r − 1) / sample_rate`.

The instrument samples on a fixed grid anchored at the payload origin, the
content instant of payload row 1. A generation gap suppresses whole segments
of that grid and a restarted instrument resumes on it, so segment
identifiers and payload rows follow from the content epoch alone.

The telemetry layers never read the payload. The flag series carries what a
downstream consumer needs from it — which delivered samples belong to an
event — and nothing else; a physical noise or waveform model is supplied
through the external source.
"""
module VirtualInstrument

using ..TelemetryCore
using CSV: CSV
using DataFrames: DataFrames, DataFrame
using Dates: Dates, DateTime, Millisecond

"""
    PayloadSource

Origin of the samples of an [`InstrumentState`](@ref). A source implements
`segment_samples(source, epoch, stop, first_row, n_samples) -> Vector{Float32}`,
the samples of the segment with content span `[epoch, stop)` whose first
sample is payload row `first_row`. Both addresses describe the same segment;
a source reads the one it is indexed by.
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

Externally supplied time series addressed by payload row: row `r` is
`samples[r]`, the sample at `origin + (r − 1) / sample_rate` of the
[`InstrumentState`](@ref) that reads it. Rows past the end read as zeros.
"""
struct ExternalSeries <: PayloadSource
    samples::Vector{Float32}
end

"""
    InstrumentState(origin, sample_rate, segment_duration_sec, data_source, ext_path;
                    markers = EventMarker[])

State of the science payload: the payload origin `origin` (the content
instant of payload row 1 and of segment 1), the content instant `last_t` of
the next segment, the segment geometry, and the [`PayloadSource`](@ref) the
samples come from.

Segments open on the grid `origin + k · segment_duration_sec`, `k ≥ 0`: the
segment opening at `epoch` has the identifier
`(epoch − origin) / segment_duration_sec + 1` ([`segment_id`](@ref)) and
starts at payload row [`payload_row`](@ref). The content clock starts at the
origin; it leaves the grid neither across a generation gap
([`advance_to!`](@ref)) nor in the instrument of a restarted emitter
([`resumed`](@ref)), so identifiers never repeat within a run and the
payload continues at the rows of the resumed content instant.

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
    const origin::DateTime
    last_t::DateTime
    const sample_rate::Float64
    const segment_duration_sec::Float64
    const source::S
end

function InstrumentState(
    origin::DateTime,
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
    return InstrumentState(origin, origin, sample_rate, segment_duration_sec, source)
end

"""
    segment_boundary(origin::DateTime, period::Millisecond, t::DateTime) -> DateTime

The first instant of the grid `origin + k · period` (`k` integer) at or
after `t`.
"""
function segment_boundary(origin::DateTime, period::Millisecond, t::DateTime)
    return origin + period * cld((t - origin).value, period.value)
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
    segment_samples(source::PayloadSource, epoch, stop, first_row, n_samples) -> Vector{Float32}

The `n_samples` samples of the segment with content span `[epoch, stop)`,
whose first sample is payload row `first_row`. A [`FlaggedSignal`](@ref) is
addressed by the span, an [`ExternalSeries`](@ref) by the rows
`first_row … first_row + n_samples − 1`; both are stateless, so the
samples of a segment depend on its position on the payload grid alone.
"""
function segment_samples(
    source::FlaggedSignal,
    epoch::DateTime,
    stop::DateTime,
    ::Int,
    n_samples::Int,
)
    first_at_or_after = searchsortedfirst(source.instants, epoch)
    flagged =
        first_at_or_after <= length(source.instants) &&
        source.instants[first_at_or_after] < stop
    return fill(Float32(flagged), n_samples)
end

function segment_samples(
    source::ExternalSeries,
    ::DateTime,
    ::DateTime,
    first_row::Int,
    n_samples::Int,
)
    first_row >= 1 || throw(ArgumentError("first_row must be ≥ 1 (got $first_row)."))
    data = zeros(Float32, n_samples)
    available = length(source.samples) - first_row + 1
    if available < n_samples
        @warn "[INSTRUMENT] External data exhausted at row $(max(first_row, length(source.samples) + 1)) of " *
              "$(length(source.samples)): padding with zeros from here on. " *
              "Provide a longer series or shorten the mission." maxlog = 1
    end
    n_copied = clamp(available, 0, n_samples)
    copyto!(data, 1, source.samples, first_row, n_copied)
    return data
end

"""
    segment_id(vi::InstrumentState, epoch::DateTime) -> Int

Identifier of the segment opening at `epoch`,
`(epoch − origin) / segment_duration_sec + 1`: segment 1 opens at the
payload origin. `ArgumentError` when `epoch` precedes the origin or is not
a grid instant.
"""
function segment_id(vi::InstrumentState, epoch::DateTime)
    period_ms = TelemetryCore.segment_period(vi.segment_duration_sec).value
    offset_ms = (epoch - vi.origin).value
    (offset_ms >= 0 && offset_ms % period_ms == 0) || throw(
        ArgumentError(
            "$epoch is not a segment boundary of the payload grid (origin $(vi.origin), period $period_ms ms).",
        ),
    )
    return offset_ms ÷ period_ms + 1
end

"""
    payload_row(vi::InstrumentState, segment_id::Integer) -> Int

Payload row of the first sample of segment `segment_id`,
`(segment_id − 1) · n + 1` with `n` = [`samples_per_segment`](@ref). When
`sample_rate × segment_duration_sec` is an integer this is
`(epoch − origin) · sample_rate + 1`, the row whose instant is the segment's
content epoch; otherwise (a configuration warned about at validation)
consecutive segments still read consecutive, disjoint rows.
"""
function payload_row(vi::InstrumentState, segment_id::Integer)
    return (segment_id - 1) * samples_per_segment(vi.sample_rate, vi.segment_duration_sec) +
           1
end

"""
    advance_to!(vi::InstrumentState, t::DateTime) -> DateTime

Resumes the content clock at the first grid instant at or after `t` after a
generation gap. The sampling phase of the payload origin is kept: a gap
suppresses whole segments and never shifts the grid. A `t` at or before the
current content instant leaves the clock unchanged. Returns the new content
instant.
"""
function advance_to!(vi::InstrumentState, t::DateTime)
    if t > vi.last_t
        period = TelemetryCore.segment_period(vi.segment_duration_sec)
        vi.last_t = segment_boundary(vi.origin, period, t)
    end
    return vi.last_t
end

"""
    resumed(vi::InstrumentState, t::DateTime) -> InstrumentState

The instrument of a restarted emitter: the payload origin, segment geometry,
and source of `vi` — an external series is not read again — with the
content clock at the first grid instant at or after `t`, and never before
the content instant of `vi`, so the replacement cannot repeat a segment of
its predecessor.
"""
function resumed(vi::InstrumentState, t::DateTime)
    period = TelemetryCore.segment_period(vi.segment_duration_sec)
    return InstrumentState(
        vi.origin,
        segment_boundary(vi.origin, period, max(t, vi.last_t)),
        vi.sample_rate,
        vi.segment_duration_sec,
        vi.source,
    )
end

"""
    next_segment!(vi::InstrumentState) -> DataSegment

The next segment of science data, stamped with its content epoch and its
[`segment_id`](@ref); advances the content clock by one segment period.
"""
function next_segment!(vi::InstrumentState)
    period = TelemetryCore.segment_period(vi.segment_duration_sec)
    n_samples = samples_per_segment(vi.sample_rate, vi.segment_duration_sec)
    id = segment_id(vi, vi.last_t)
    data = segment_samples(
        vi.source,
        vi.last_t,
        vi.last_t + period,
        payload_row(vi, id),
        n_samples,
    )
    segment = TelemetryCore.DataSegment(id, vi.last_t, data)
    vi.last_t += period
    return segment
end

end # module VirtualInstrument
