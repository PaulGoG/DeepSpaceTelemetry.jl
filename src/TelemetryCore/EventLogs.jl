# --- Data Structures ---
"""
    PAYLOAD_COLUMN_DEFAULT

The name of the one payload column of a synthetic run and of an external
run without `physics.external_data_columns`: `Amplitude`.
"""
const PAYLOAD_COLUMN_DEFAULT = "Amplitude"

"""
    DataSegment(id::Int, timestamp::DateTime, data::Matrix{Float32}, columns::Vector{String})
    DataSegment(id::Integer, timestamp::DateTime, data::AbstractVector{<:Real})

One `segment_duration_sec` span of the observed time series: the `Float32`
samples `data`, one row per sample and one column per payload column named
in `columns`, the first sample at the mission instant `timestamp`. `id` is
the segment's position on the payload grid,
`(timestamp − origin) / segment_duration_sec + 1`
([`DeepSpaceTelemetry.VirtualInstrument.segment_id`](@ref)), unique within
a run. The vector form builds a one-column segment named
[`PAYLOAD_COLUMN_DEFAULT`](@ref). Throws a `DimensionMismatch` when `data`
does not have `length(columns)` columns and an `ArgumentError` when
`columns` is empty.
"""
struct DataSegment
    id::Int
    timestamp::DateTime
    data::Matrix{Float32}
    columns::Vector{String}
    function DataSegment(
        id::Int,
        timestamp::DateTime,
        data::Matrix{Float32},
        columns::Vector{String},
    )
        isempty(columns) &&
            throw(ArgumentError("A segment needs at least one payload column."))
        size(data, 2) == length(columns) || throw(
            DimensionMismatch(
                "segment $id holds $(size(data, 2)) columns for $(length(columns)) names.",
            ),
        )
        return new(id, timestamp, data, columns)
    end
end
DataSegment(id::Integer, timestamp::DateTime, data::AbstractVector{<:Real}) = DataSegment(
    Int(id),
    timestamp,
    reshape(Vector{Float32}(data), :, 1),
    [PAYLOAD_COLUMN_DEFAULT],
)

"""
    segment_column(seg::DataSegment, column::Union{Integer,AbstractString}) -> Vector{Float32}

The samples of one payload column of `seg`, by index or by name; an
`ArgumentError` names the columns when `column` is not one of them.
"""
function segment_column(seg::DataSegment, column::Union{Integer,AbstractString})
    j = if column isa AbstractString
        findfirst(==(column), seg.columns)
    else
        1 <= column <= length(seg.columns) ? Int(column) : nothing
    end
    j === nothing && throw(
        ArgumentError(
            "Segment $(seg.id) has no payload column $(repr(column)) (columns: $(join(seg.columns, ", "))).",
        ),
    )
    return seg.data[:, j]
end

"""
    DataBatch(id::Int, segments::Vector{DataSegment}, created_at::DateTime)

A collection of [`DataSegment`](@ref)s prepared for bulk transmission over
the DSN: `id` is the batch counter, `segments` the payload in content
order, and `created_at` the mission instant of finalization (when the
batch became transmittable; the content epoch is `segments[1].timestamp`).
"""
struct DataBatch
    id::Int
    segments::Vector{DataSegment}
    created_at::DateTime
end

# --- Mission metrics ---
"""
    MissionMetrics

A snapshot of the mission state including queue sizes, effective and nominal
bandwidth, packet-loss counters, and the disruption flag. `bandwidth_pct` is
the *effective* link capacity (visibility × disruption factor);
`nominal_bandwidth_pct` is the visibility profile alone.
"""
struct MissionMetrics
    sim_time::DateTime
    wall_time::DateTime
    hours_elapsed::Float64
    bandwidth_pct::Float64
    onboard_buffer::Int
    link_buffer::Int
    ground_total::Int
    ground_live::Int
    ground_arch::Int
    nominal_bandwidth_pct::Float64
    lost_count::Int
    retry_count::Int
    disruption_active::Bool
end

"""
    save_metrics(run_dir::String, m::MissionMetrics)

Appends a new metrics snapshot to `mission_profile.csv`. The packet-loss and
disruption columns are appended after the legacy columns so pre-loss readers
of old profiles keep working.
"""
function save_metrics(run_dir::String, m::MissionMetrics)
    log_path = joinpath(run_dir, "mission_profile.csv")
    exists = isfile(log_path)

    df = DataFrame(
        SimTime = m.sim_time,
        WallTime = m.wall_time,
        Mission_Day = round(m.hours_elapsed / 24.0, digits = 2),
        Hours_Elapsed = round(m.hours_elapsed, digits = 2),
        Bandwidth_Pct = round(m.bandwidth_pct, digits = 1),
        Onboard_Buffer = m.onboard_buffer,
        Link_Buffer = m.link_buffer,
        Ground_Total = m.ground_total,
        Ground_Live = m.ground_live,
        Ground_Arch = m.ground_arch,
        Nominal_Bandwidth_Pct = round(m.nominal_bandwidth_pct, digits = 1),
        Lost_Count = m.lost_count,
        Retry_Count = m.retry_count,
        Disruption_Active = m.disruption_active,
    )

    # Row-wise append: the profile is an append-only log of the run, so no
    # backup rotation applies to it.
    write_table(log_path, df; append = exists)
end

# --- Ground-Truth Event Logs ---
"""
    log_tx_event(run_dir::String, sim_t::DateTime, batch::String, event::String)

Appends one row to `events_tx.csv`. Events: `"gen"` (batch finalized
onboard), `"tx"` (batch placed on the downlink), `"marker"` (`sim_t` an
event-marker instant, `batch` the batch holding it), and the
`"gap_start"`/`"gap_end"` pair bounding a generation gap (`batch` =
`SCHEDULED`, `RECORDER`, or `STREAM`); marker and gap rows preserve the
batch states. With [`log_rx_event`](@ref) it records the exact per-batch
state history that the mask and animation reconstruction replays. The
emitter writes the file; the supervisor appends the `STREAM` pair only
while no emitter is live, so there is one writer at a time and no lock.
"""
function log_tx_event(run_dir::String, sim_t::DateTime, batch::String, event::String)
    path = joinpath(run_dir, "events_tx.csv")
    df = DataFrame(SimTime = sim_t, Batch = batch, Event = event)
    write_table(path, df; append = isfile(path))
end

"""
    log_rx_event(run_dir::String, sim_t::DateTime, batch::String, event::String, attempt::Int)

Appends one receiver-side batch milestone to `events_rx.csv`. Events:
`"ingested"` (batch reached the ground archive), `"retry"` (transfer attempt
lost, batch remains on the link), `"lost"` (retry budget exhausted, batch
moved to `lost/`), and `"pruned"` (retention custodian deleted the delivered
payload CSVs after the grace window; state-preserving for the mask replay).
`attempt` counts failed transfer attempts so far (0 for `"pruned"`).
Only the receiver task writes this file (single-writer; no lock needed).
"""
function log_rx_event(
    run_dir::String,
    sim_t::DateTime,
    batch::String,
    event::String,
    attempt::Int,
)
    path = joinpath(run_dir, "events_rx.csv")
    df = DataFrame(SimTime = sim_t, Batch = batch, Event = event, Attempt = attempt)
    write_table(path, df; append = isfile(path))
end
