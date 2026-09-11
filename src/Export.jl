"""
    Export

HDF5 product export: every consumer-facing product of a run — event logs,
metrics profile, batch-state timeline, batch epochs, point-wise masks,
metrology tables, markers, component events — in one self-describing file
with the run's provenance as attributes, for analysis pipelines that read
HDF5 rather than a directory of CSV files. The CSV products remain the
primary interface; the export is a derived, regenerable view of them
([`export_hdf5`](@ref)).
"""
module Export

using ..TelemetryCore
using CSV: CSV
using DataFrames: DataFrame, nrow
using Dates: DateTime, now
using HDF5: HDF5, h5open, create_group
using TOML: TOML

"""
    FORMAT_VERSION

Layout version of the exported file, stored as the root attribute
`format_version`; incremented when a group or dataset changes meaning.
"""
const FORMAT_VERSION = "1"

"""
    TABLE_PRODUCTS

`(group, relative path)` pairs of the tabular CSV products written by
[`export_hdf5`](@ref) through [`write_table!`](@ref); absent files are
skipped.
"""
const TABLE_PRODUCTS = (
    ("events/tx", "events_tx.csv"),
    ("events/rx", "events_rx.csv"),
    ("metrics/mission_profile", "mission_profile.csv"),
    ("masks/batch_epochs", joinpath("masks", "batch_epochs.csv")),
    ("metrology/alert_latency", "alert_latency.csv"),
    ("metrology/alert_latency_markers", "alert_latency_markers.csv"),
    ("metrology/delivery_delay", "delivery_delay.csv"),
    ("markers", "markers.csv"),
    ("component_events", "component_events.csv"),
)

"""
    ensure_group(parent, path::String)

The group at the slash-separated `path` below `parent`, creating the
missing levels.
"""
function ensure_group(parent::Union{HDF5.File,HDF5.Group}, path::String)
    g::Union{HDF5.File,HDF5.Group} = parent
    for part in split(path, '/'; keepempty = false)
        name = String(part)
        g = haskey(g, name) ? (g[name]::HDF5.Group) : create_group(g, name)
    end
    return g
end

"""
    write_column!(g::HDF5.Group, name::String, values::AbstractVector, epoch::DateTime)

One CSV column as HDF5 datasets under `g`: a `DateTime` column becomes
`name` (`Float64` seconds since `epoch`, `NaN` for missing) plus
`name_iso` (ISO-8601 strings); booleans become `UInt8` (`0`/`1`, the
sentinel `0xff` for missing); integers stay `Int64` unless a value is
missing (then `Float64` with `NaN`); other reals become `Float64` with
`NaN` for missing; everything else is written as strings with `""` for
missing.
"""
function write_column!(g::HDF5.Group, name::String, values::AbstractVector, epoch::DateTime)
    T = Base.nonmissingtype(eltype(values))
    has_missing = any(ismissing, values)
    if T <: DateTime
        g[name] = Float64[ismissing(v) ? NaN : (v - epoch).value / 1000 for v in values]
        HDF5.write_attribute(g[name]::HDF5.Dataset, "unit", "s since start_sim_time")
        g[name*"_iso"] = String[ismissing(v) ? "" : string(v) for v in values]
    elseif T <: Bool
        g[name] = UInt8[ismissing(v) ? 0xff : UInt8(v) for v in values]
    elseif T <: Integer && !has_missing
        g[name] = Int64[Int64(v) for v in values]
    elseif T <: Real
        g[name] = Float64[ismissing(v) ? NaN : Float64(v) for v in values]
    else
        g[name] = String[ismissing(v) ? "" : string(v) for v in values]
    end
    return g
end

"""
    write_table!(file::HDF5.File, group::String, df::DataFrame, epoch::DateTime, source::String)

A CSV product as one HDF5 group: one dataset per column
([`write_column!`](@ref)), the attributes `source` (the relative CSV path)
and `rows`; an empty table yields the group with its attributes only.
"""
function write_table!(
    file::HDF5.File,
    group::String,
    df::DataFrame,
    epoch::DateTime,
    source::String,
)
    g = ensure_group(file, group)::HDF5.Group
    HDF5.write_attribute(g, "source", source)
    HDF5.write_attribute(g, "rows", nrow(df))
    nrow(df) == 0 && return g
    for col in names(df)
        write_column!(g, String(col), df[!, col], epoch)
    end
    return g
end

"""
    write_mask_timeline!(file::HDF5.File, run_dir::String, epoch::DateTime)

`masks/telemetry_mask_timeline.csv` as `masks/timeline`: `states` — the
`Int8` state matrix laid out so that C-order readers (h5py, NumPy) index
`states[snapshot, batch]` while Julia reads its transpose `(batch,
snapshot)` — with `batch_id`, the snapshot instants (`SimTime`,
`SimTime_iso`), and the state-code attribute. Nothing is written when the
timeline is absent.
"""
function write_mask_timeline!(file::HDF5.File, run_dir::String, epoch::DateTime)
    csv = joinpath(run_dir, "masks", "telemetry_mask_timeline.csv")
    isfile(csv) || return nothing
    df = CSV.read(csv, DataFrame)
    g = ensure_group(file, "masks/timeline")::HDF5.Group
    HDF5.write_attribute(g, "source", joinpath("masks", "telemetry_mask_timeline.csv"))
    HDF5.write_attribute(
        g,
        "state_codes",
        "0 = Future, 1 = Onboard, 2 = Link, 3 = Ground, 4 = Lost",
    )
    HDF5.write_attribute(
        g,
        "layout",
        "states[snapshot, batch] for C-order readers; Julia reads (batch, snapshot)",
    )
    batch_cols = filter(c -> startswith(c, "Batch_"), names(df))
    states = Matrix{Int8}(undef, length(batch_cols), nrow(df))
    for (j, c) in enumerate(batch_cols)
        states[j, :] = Int8.(df[!, c])
    end
    g["states"] = states
    g["batch_id"] = Int64[parse(Int, chopprefix(c, "Batch_")) for c in batch_cols]
    write_column!(g, "SimTime", df.SimTime, epoch)
    return g
end

"""
    write_pointwise_masks!(file::HDF5.File, run_dir::String)

Every `masks/pointwise_mask_*.csv` expansion as
`masks/pointwise/<stem>/Ground_Available` (`Int8` 0/1 per sample, sample
`k` at index `k`).
"""
function write_pointwise_masks!(file::HDF5.File, run_dir::String)
    masks_dir = joinpath(run_dir, "masks")
    isdir(masks_dir) || return nothing
    for f in sort!(filter(startswith("pointwise_mask_"), readdir(masks_dir)))
        endswith(f, ".csv") || continue
        df = CSV.read(joinpath(masks_dir, f), DataFrame)
        hasproperty(df, :Ground_Available) || continue
        g = ensure_group(file, "masks/pointwise/" * splitext(f)[1])
        HDF5.write_attribute(g, "source", joinpath("masks", f))
        g["Ground_Available"] = Int8.(df.Ground_Available)
    end
    return nothing
end

"""
    write_provenance!(file::HDF5.File, run_dir::String, cfg::AbstractDict, epoch::DateTime)

Root attributes: `format_version`, `run_id`, `start_sim_time`, `speed_up`,
`exported_at`, the platform fingerprint of the run snapshot
(`[provenance.platform]`: hostname, package version, git commit, Julia
version, …), and `config_snapshot` — the run's configuration as TOML
text.
"""
function write_provenance!(
    file::HDF5.File,
    run_dir::String,
    cfg::AbstractDict,
    epoch::DateTime,
)
    HDF5.write_attribute(file, "format_version", FORMAT_VERSION)
    HDF5.write_attribute(file, "run_id", basename(rstrip(run_dir, '/')))
    HDF5.write_attribute(file, "start_sim_time", string(epoch))
    sim = get(cfg, "simulation", Dict{String,Any}())
    HDF5.write_attribute(file, "speed_up", Float64(get(sim, "speed_up", NaN)))
    HDF5.write_attribute(file, "exported_at", string(now()))
    platform =
        get(get(cfg, "provenance", Dict{String,Any}()), "platform", Dict{String,Any}())
    for (key, value) in platform
        value isa Union{AbstractString,Real} || continue
        HDF5.write_attribute(
            file,
            String(key),
            value isa AbstractString ? String(value) : value,
        )
    end
    HDF5.write_attribute(file, "config_snapshot", sprint(TOML.print, cfg))
    return file
end

"""
    export_hdf5(run_dir::String; path = joinpath(run_dir, "products.h5")) -> String

Writes the run's products into one HDF5 file (default
`<run_dir>/products.h5`, an existing file is rotated to `products#k.h5`):
the tabular products of [`TABLE_PRODUCTS`](@ref) as column datasets, the
batch-state timeline ([`write_mask_timeline!`](@ref)), the point-wise
masks ([`write_pointwise_masks!`](@ref)), and the provenance attributes
([`write_provenance!`](@ref)). Times are seconds since the run's
`start_sim_time` with ISO-8601 twins. Returns the file path.
"""
function export_hdf5(run_dir::String; path::String = joinpath(run_dir, "products.h5"))
    isdir(run_dir) || throw(ArgumentError("[EXPORT] Run directory not found: $run_dir"))
    cfg = TelemetryCore.load_run_config(run_dir)
    sim = get(cfg, "simulation", Dict{String,Any}())
    haskey(sim, "start_sim_time") || throw(
        ArgumentError(
            "[EXPORT] simulation.start_sim_time missing from the run snapshot of $run_dir.",
        ),
    )
    epoch =
        TelemetryCore.parsed_datetime(sim["start_sim_time"], "simulation.start_sim_time")
    mkpath(dirname(path))
    TelemetryCore.backup_existing(path)
    h5open(path, "w") do file
        write_provenance!(file, run_dir, cfg, epoch)
        for (group, rel) in TABLE_PRODUCTS
            csv = joinpath(run_dir, rel)
            isfile(csv) || continue
            df = CSV.read(csv, DataFrame)
            rel == "mission_profile.csv" && TelemetryCore.normalize_profile!(df)
            write_table!(file, group, df, epoch, rel)
        end
        write_mask_timeline!(file, run_dir, epoch)
        write_pointwise_masks!(file, run_dir)
    end
    @info "[POST] HDF5 product export saved: $(relpath(path, run_dir))"
    return path
end

end # module Export
