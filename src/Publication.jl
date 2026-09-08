"""
    Publication

Publication figure export: every figure of a run re-rendered at a declared
printed width in a vector format, into one directory with a provenance
sidecar, so a manuscript's figure directory is populated from the run
that produced the numbers ([`export_publication_figures`](@ref)). The
figures are the same functions the post-processing renders — the export
changes only the print scale ([`PlotTheme.style_for_width`](@ref)), the
format, the destination, and the file-name suffix carrying the run ID.
"""
module Publication

using ..TelemetryCore
using ..PlotTheme
using ..Receiver
using ..Metrology
using Dates: now
using SHA: sha256
using TOML: TOML

"""
    export_publication_figures(run_dir::String; format = "pdf", column_width_mm = 178.0, export_dir = "") -> Vector{String}

Renders the mission summary, every session figure, and the metrology
figures of the run at `column_width_mm` (178 = the double-column design
width; 86–90 for a single column) in `format` (`"pdf"` or `"svg"`) into
`export_dir` (default `<run_dir>/publication`), each file named
`<stem>__<run_id>.<format>`, and writes `PROVENANCE.toml` beside them
([`write_provenance`](@ref)). The metrology tables of the run are not
rewritten. Returns the figure paths.
"""
function export_publication_figures(
    run_dir::String;
    format::String = "pdf",
    column_width_mm::Real = 178.0,
    export_dir::String = "",
)
    isdir(run_dir) ||
        throw(ArgumentError("[PUBLICATION] Run directory not found: $run_dir"))
    format in ("pdf", "svg") || throw(
        ArgumentError("[PUBLICATION] format must be \"pdf\" or \"svg\" (got \"$format\")."),
    )
    column_width_mm > 0 || throw(
        ArgumentError("[PUBLICATION] column_width_mm must be > 0 (got $column_width_mm)."),
    )
    run_id = basename(rstrip(run_dir, '/'))
    dir = isempty(export_dir) ? joinpath(run_dir, "publication") : abspath(export_dir)
    mkpath(dir)
    style = PlotTheme.style_for_width(column_width_mm)
    suffix = "__" * run_id
    formats = (format,)
    cfg = TelemetryCore.load_run_config(run_dir)
    pp = get(cfg, "post_processing", Dict{String,Any}())

    paths =
        Receiver.generate_mission_plots(run_dir; style, plots_dir = dir, formats, suffix)
    if get(pp, "alert_latency", true)
        p = Metrology.plot_alert_latency(
            run_dir;
            lookback_hours = Float64(get(pp, "alert_lookback_hours", 72.0)),
            processing_latency_hours = TelemetryCore.ground_settings(cfg).processing_latency_hours,
            style,
            plots_dir = dir,
            formats,
            suffix,
            write_tables = false,
        )
        p === nothing || push!(paths, p)
    end
    if get(pp, "delivery_delay", true)
        p = Metrology.plot_delivery_delay(
            run_dir;
            requirement_hours = Float64(get(pp, "delivery_requirement_hours", 24.0)),
            style,
            plots_dir = dir,
            formats,
            suffix,
            write_tables = false,
        )
        p === nothing || push!(paths, p)
    end
    write_provenance(dir, run_dir, cfg, paths, Float64(column_width_mm), format)
    @info "[POST] Publication figures exported: $(length(paths)) files in $dir."
    return paths
end

"""
    write_provenance(dir, run_dir, cfg, paths, column_width_mm, format) -> String

Writes `<dir>/PROVENANCE.toml` (an existing file is rotated): the run ID
and directory, the export instant, width and format, the package version
and git commit recorded in the run snapshot, the SHA-256 of the snapshot,
and the exported file names — so every published panel traces back to a
configuration and a commit.
"""
function write_provenance(
    dir::String,
    run_dir::String,
    cfg::AbstractDict,
    paths::Vector{String},
    column_width_mm::Float64,
    format::String,
)
    platform =
        get(get(cfg, "provenance", Dict{String,Any}()), "platform", Dict{String,Any}())
    snapshot = joinpath(run_dir, "config_snapshot.toml")
    record = Dict{String,Any}(
        "export" => Dict{String,Any}(
            "run_id" => basename(rstrip(run_dir, '/')),
            "run_directory" => abspath(run_dir),
            "exported_at" => string(now()),
            "column_width_mm" => column_width_mm,
            "format" => format,
            "package_version" => string(
                get(platform, "package_version", string(pkgversion(Publication))),
            ),
            "git_commit" => string(get(platform, "git_commit", "")),
            "config_snapshot_sha256" =>
                isfile(snapshot) ? bytes2hex(sha256(read(snapshot))) : "",
            "figures" => [basename(p) for p in paths],
        ),
    )
    path = joinpath(dir, "PROVENANCE.toml")
    TelemetryCore.backup_existing(path)
    open(path, "w") do io
        TOML.print(io, record)
    end
    return path
end

end # module Publication
