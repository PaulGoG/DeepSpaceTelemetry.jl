"""
    Sweeps

Ensembles and sweeps on the tick clock: the same configuration run over a
set of seeds, with optional overrides of any key, and the realized totals of
every run gathered into one table. On a given platform a seed reproduces a
run's event logs to the byte and its metrics profile apart from the
`WallTime` column. [`run_sweep`](@ref) drives the runs, serially or on
worker processes; [`summarize_run`](@ref) reads one run's totals; the
products land under `<data root>/sweeps/<prefix>/`.
"""
module Sweeps

using ..TelemetryCore: TelemetryCore
using ..Supervisor
using DataFrames: DataFrame, nrow
using Dates: now
using Distributed: Distributed, addprocs, nprocs, pmap
using Logging: NullLogger, with_logger
using TOML: TOML

"""
    FIGURE_FREE_POST_PROCESSING

The post-processing switches a sweep run sets: no mask timeline, no
batch-state raster or session figures, no HDF5 export. The deprecated
point-wise mask keys are removed, which leaves the expansion off.
The publication export is switched off by [`sweep_configuration`](@ref),
and [`run_one`](@ref) runs the mission with `figures = false`, so no figure
is drawn. The gap table and the metrology tables, which the summary reads,
are written for every run.
"""
const FIGURE_FREE_POST_PROCESSING = (
    "generate_mask_timeline" => false,
    "state_raster" => false,
    "session_figures" => false,
    "hdf5_export" => false,
)

"""
    apply_override!(cfg::AbstractDict, key::AbstractString, value) -> AbstractDict

Sets the dotted `key` (`section.key`, any depth) of `cfg` to `value`,
creating the sections on the way. A string `value` is converted by
[`parse_override`](@ref): `true`, `3`, `0.25`, or a quoted or bare string.
"""
function apply_override!(cfg::AbstractDict, key::AbstractString, value)
    parts = split(String(key), '.')
    length(parts) >= 2 ||
        throw(ArgumentError("[SWEEP] An override key is section.key (got \"$key\")."))
    node = cfg
    for part in parts[1:(end-1)]
        node = get!(Dict{String,Any}, node, String(part))
        node isa AbstractDict || throw(
            ArgumentError("[SWEEP] $key: $part is not a section of the configuration."),
        )
    end
    node[String(parts[end])] = value isa AbstractString ? parse_override(value) : value
    return cfg
end

"""
    parse_override(text::AbstractString)

The value of an override given as text: a boolean, an integer, a float, or
the string itself (quotes stripped).
"""
function parse_override(text::AbstractString)
    s = strip(String(text))
    s == "true" && return true
    s == "false" && return false
    i = tryparse(Int, s)
    i === nothing || return i
    x = tryparse(Float64, s)
    x === nothing || return x
    return strip(s, ['"', '\''])
end

"""
    sweep_configuration(cfg::AbstractDict, seed::Integer; overrides = String[]) -> Dict{String,Any}

The configuration of one sweep run: `cfg` on the tick clock
([`TelemetryCore.tick_configuration`](@ref)), every `"section.key=value"`
override applied, `simulation.rng_seed = seed`, the switches of
[`FIGURE_FREE_POST_PROCESSING`](@ref), and the publication export off. The
figures themselves are skipped by [`run_one`](@ref).
"""
function sweep_configuration(
    cfg::AbstractDict,
    seed::Integer;
    overrides::AbstractVector{<:AbstractString} = String[],
)
    out = TelemetryCore.tick_configuration(cfg)
    for item in overrides
        key, value = split_override(item)
        apply_override!(out, key, value)
    end
    out["simulation"]["rng_seed"] = Int(seed)
    post = get!(Dict{String,Any}, out, "post_processing")
    for (key, value) in FIGURE_FREE_POST_PROCESSING
        post[key] = value
    end
    delete!(post, "expand_to_pointwise_masks")
    delete!(post, "target_event_rows")
    publication = get!(Dict{String,Any}, post, "publication")
    publication["enabled"] = false
    return out
end

"""
    split_override(item::AbstractString) -> Tuple{String,String}

`"section.key=value"` into its key and its value text.
"""
function split_override(item::AbstractString)
    i = findfirst('=', item)
    i === nothing &&
        throw(ArgumentError("[SWEEP] An override is section.key=value (got \"$item\")."))
    return String(strip(item[1:(i-1)])), String(strip(item[(i+1):end]))
end

"""
    summarize_run(run_dir::String) -> NamedTuple

The realized totals of one run: the counters of the last row of
`mission_profile.csv`, the generated count and the share within the
delivery requirement from `delivery_delay.csv`, the alert-latency medians
at 24 h and 72 h (realized and counterfactual) from `alert_latency.csv`,
and the hole count of `masks/gaps.csv`. A product that is absent leaves its
fields `missing`.
"""
function summarize_run(run_dir::String)
    profile = TelemetryCore.normalize_profile!(
        TelemetryCore.read_table(joinpath(run_dir, "mission_profile.csv")),
    )
    last = profile[end, :]
    generated = within = missing
    delay_path = joinpath(run_dir, "delivery_delay.csv")
    if isfile(delay_path)
        delay = TelemetryCore.read_table(delay_path)
        generated = nrow(delay)
        requirement = Float64(
            get(
                get(
                    TelemetryCore.load_run_config(run_dir),
                    "post_processing",
                    Dict{String,Any}(),
                ),
                "delivery_requirement_hours",
                24.0,
            ),
        )
        within =
            count(d -> !ismissing(d) && d <= requirement, delay.Delay_Hours) /
            max(generated, 1)
    end
    medians = Dict{Symbol,Union{Missing,Float64}}(
        :alert24_realized => missing,
        :alert24_fifo => missing,
        :alert72_realized => missing,
        :alert72_fifo => missing,
    )
    alert_path = joinpath(run_dir, "alert_latency.csv")
    if isfile(alert_path)
        alert = TelemetryCore.read_table(alert_path)
        for (hours, realized, fifo) in (
            (24.0, :alert24_realized, :alert24_fifo),
            (72.0, :alert72_realized, :alert72_fifo),
        )
            rows = alert[alert.Lookback_Hours .== hours, :]
            nrow(rows) == 1 || continue
            medians[realized] = Float64(rows.LIFO_Median_Hours[1])
            medians[fifo] = Float64(rows.FIFO_Median_Hours[1])
        end
    end
    gaps_path = joinpath(run_dir, "masks", "gaps.csv")
    holes = isfile(gaps_path) ? nrow(TelemetryCore.read_table(gaps_path)) : missing
    return (
        run_id = basename(run_dir),
        generated = generated,
        ground_total = Int(last.Ground_Total),
        ground_live = Int(last.Ground_Live),
        ground_archive = Int(last.Ground_Arch),
        lost = Int(last.Lost_Count),
        retries = Int(last.Retry_Count),
        onboard_end = Int(last.Onboard_Buffer),
        link_end = Int(last.Link_Buffer),
        within_requirement = within,
        alert24_realized = medians[:alert24_realized],
        alert24_fifo = medians[:alert24_fifo],
        alert72_realized = medians[:alert72_realized],
        alert72_fifo = medians[:alert72_fifo],
        holes = holes,
    )
end

"""
    run_one(cfg::Dict{String,Any}, run_id::String, data_root::String) -> String

One sweep run in the calling process, the body every worker executes: the
mission headless under `data_root`, with the console and the global logger
silenced; the run's own logs still go to its directory. Returns the run
directory.
"""
function run_one(cfg::Dict{String,Any}, run_id::String, data_root::String)
    return with_logger(NullLogger()) do
        Supervisor.run_mission(
            cfg;
            run_id = run_id,
            orig_stdout = devnull,
            figures = false,
            data_root = data_root,
        )
    end
end

"""
    run_sweep(cfg::AbstractDict; prefix::AbstractString, seeds, overrides = String[], workers = 0, data_root = TelemetryCore.DATA_ROOT[]) -> NamedTuple

Runs `cfg` on the tick clock once per seed in `seeds`, as
`<prefix>_seed<seed>` under `<data_root>/runs/`, with the `overrides`
applied to every run ([`sweep_configuration`](@ref)); with `workers > 0`
the runs are distributed over that many worker processes (started with the
active project when fewer exist), otherwise they run one after another in
this process. Writes `<data_root>/sweeps/<prefix>/summary.csv`, one row per
run ([`summarize_run`](@ref), with the seed first), and `sweep.toml`, the
sweep's provenance: the base configuration's hash, the overrides, the
seeds, the package version and source identity
([`TelemetryCore.source_identity`](@ref)), the date. Returns `(summary, dir)`.
"""
function run_sweep(
    cfg::AbstractDict;
    prefix::AbstractString,
    seeds::AbstractVector{<:Integer},
    overrides::AbstractVector{<:AbstractString} = String[],
    workers::Integer = 0,
    data_root::AbstractString = TelemetryCore.DATA_ROOT[],
)
    occursin(r"^[A-Za-z0-9_.-]+$", prefix) || throw(
        ArgumentError(
            "[SWEEP] The prefix may hold letters, digits, '_', '.', and '-' only (got \"$prefix\").",
        ),
    )
    seed_list = Vector{Int}(collect(seeds))
    isempty(seed_list) && throw(ArgumentError("[SWEEP] No seeds given."))
    allunique(seed_list) || throw(ArgumentError("[SWEEP] The seeds must be distinct."))
    root = abspath(String(data_root))
    jobs = [
        (sweep_configuration(cfg, seed; overrides = overrides), "$(prefix)_seed$(seed)") for seed in seed_list
    ]
    # Every configuration validates before the first run starts.
    foreach(job -> TelemetryCore.validate_config(job[1]), jobs)
    run_dirs = Vector{String}(undef, length(jobs))
    if workers > 0
        missing_workers = Int(workers) - (nprocs() - 1)
        missing_workers > 0 &&
            addprocs(missing_workers; exeflags = "--project=$(Base.active_project())")
        Distributed.remotecall_eval(
            Main,
            Distributed.workers(),
            :(using DeepSpaceTelemetry),
        )
        run_dirs .= String.(pmap(job -> run_one(job[1], job[2], root), jobs))
    else
        for (i, job) in enumerate(jobs)
            run_dirs[i] = run_one(job[1], job[2], root)
        end
    end
    rows = [
        merge((seed = seed_list[i],), summarize_run(run_dirs[i])) for
        i in eachindex(seed_list)
    ]
    summary = DataFrame(rows)
    dir = joinpath(root, "sweeps", String(prefix))
    mkpath(dir)
    TelemetryCore.safe_csv_write(joinpath(dir, "summary.csv"), summary)
    provenance = Dict{String,Any}(
        "prefix" => String(prefix),
        "seeds" => seed_list,
        "overrides" => String.(collect(overrides)),
        "mode" => "tick",
        "base_config_sha256" => TelemetryCore.config_sha256(cfg),
        "package_version" => string(pkgversion(parentmodule(@__MODULE__))),
        "runs" => [basename(d) for d in run_dirs],
        "written_at" => string(now()),
    )
    for (key, value) in pairs(TelemetryCore.source_identity())
        provenance[String(key)] = value
    end
    path = joinpath(dir, "sweep.toml")
    TelemetryCore.backup_existing(path)
    open(path, "w") do io
        TOML.print(io, provenance)
    end
    return (summary = summary, dir = dir)
end

end # module Sweeps
