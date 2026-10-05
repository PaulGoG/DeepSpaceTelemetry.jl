include(joinpath(@__DIR__, "activate.jl"))
using DeepSpaceTelemetry
using Dates
using SHA: sha256
using TOML

# Runs every scenario of the gallery table one after another, reduces the
# listed run products to the published size, and writes
# docs/src/assets/PROVENANCE.toml with the record of every run and file.
#
#     julia docs/render_assets.jl [PREFIX]
#
# Run IDs are <PREFIX>_<SCENARIO>, the default prefix is DOCS. A completed run
# of the same ID is reused, so a refresh at a new commit takes a new prefix or
# a purge of the old runs with scripts/maintenance/cleanup.jl. The runs are
# paced against wall time and therefore need an otherwise idle host.
# ImageMagick (magick) must be on the PATH.

"""
Root of the package repository; child processes run here and recorded source
paths are relative to it.
"""
const REPO = normpath(joinpath(@__DIR__, ".."))

"""
Asset directory of the manual; the published files and `PROVENANCE.toml` live here.
"""
const ASSET_DIR = joinpath(@__DIR__, "src", "assets")

"""
Subdirectory of [`ASSET_DIR`](@ref) that receives the gallery files.
"""
const GALLERY_SUBDIR = "gallery"

"""
Run-ID prefix used when none is given on the command line.
"""
const DEFAULT_PREFIX = "DOCS"

"""
Thread count of every child process.
"""
const RUN_THREADS = 3

"""
Published width of every PNG, in pixels.
"""
const PNG_WIDTH_PX = 1400

"""
One-minute load average above which a run warns that the host is loaded.
"""
const LOAD_WARN = 1.0

"""
File name of the web-profile batch-routing animation inside `<run_dir>/plots/`.
"""
const WEB_ANIMATION = "telemetry_animation_web.gif"

"""
Series written by `scripts/maintenance/generate_example_strain.jl`, relative to
the repository; the one external input this script generates when absent.
"""
const EXAMPLE_SERIES = joinpath("data", "example_external_strain.csv")

"""
Accessor of the canonical run directory, `TelemetryCore.run_directory`.
"""
const run_directory = DeepSpaceTelemetry.TelemetryCore.run_directory

"""
Gallery table. Each entry names a scenario file stem under `scenarios/`, the
stems of the figures taken from `<run_dir>/plots/` (PNG), and whether the
web-profile batch-routing animation is published.
"""
const GALLERY = (
    (scenario = "nominal_8h", figures = ("mission_summary_global",), animation = false),
    (
        scenario = "stress_8h_bursty",
        figures = (
            "mission_summary_global",
            "delivery_delay",
            "alert_latency",
            "state_raster",
            "session_day04_low_latency_detail",
        ),
        animation = true,
    ),
    (
        scenario = "recovery_12h_seasonal",
        figures = ("mission_summary_global", "delivery_delay"),
        animation = false,
    ),
    (
        scenario = "abstraction_gaussian_peak",
        figures = ("mission_summary_global", "session_day00_detail"),
        animation = false,
    ),
    (
        scenario = "backlog_recovery_sine",
        figures = ("mission_summary_global",),
        animation = false,
    ),
    (
        scenario = "drop_policy",
        figures = ("mission_summary_global", "state_raster"),
        animation = false,
    ),
    (
        scenario = "explicit_schedule",
        figures = ("mission_summary_global",),
        animation = false,
    ),
    (
        scenario = "long_30d_seasonal",
        figures = ("mission_summary_global", "state_raster"),
        animation = false,
    ),
    (
        scenario = "long_segments_2400s",
        figures = ("mission_summary_global", "state_raster"),
        animation = false,
    ),
    (
        scenario = "external_ingest",
        figures = ("mission_summary_global",),
        animation = false,
    ),
)

"""
    julia_command() -> Cmd

Julia executable of the running session with [`RUN_THREADS`](@ref) threads and
no startup file. Returns the command prefix shared by every child process.
"""
function julia_command()
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    return `$julia --threads=$(RUN_THREADS) --startup-file=no`
end

"""
    run_id(prefix::AbstractString, scenario::AbstractString) -> String

Run ID of a gallery scenario: the prefix, an underscore, and the upper-cased
scenario stem.
"""
run_id(prefix::AbstractString, scenario::AbstractString) =
    string(prefix, "_", uppercase(scenario))

"""
    ensure_external_series(entry) -> Nothing

Generates the example series when a scenario with
`physics.data_source = "external"` reads it and it is absent. Throws when the
scenario reads any other file that does not exist.
"""
function ensure_external_series(entry)
    scenario = TOML.parsefile(joinpath(REPO, "scenarios", entry.scenario * ".toml"))
    physics = get(scenario, "physics", Dict{String,Any}())
    get(physics, "data_source", "synthetic") == "external" || return nothing
    series = String(get(physics, "external_data_path", ""))
    path = isabspath(series) ? series : joinpath(REPO, series)
    isfile(path) && return nothing
    normpath(path) == normpath(joinpath(REPO, EXAMPLE_SERIES)) || error(
        "[ASSETS] External series \"$series\" of scenario $(entry.scenario) not found.",
    )
    println("[ASSETS] Generating the example external series ...")
    script = joinpath("scripts", "maintenance", "generate_example_strain.jl")
    run(Cmd(`$(julia_command()) $script`; dir = REPO))
    return nothing
end

"""
    ensure_run(prefix, entry) -> String

Runs the scenario of a gallery entry as `<prefix>_<SCENARIO>` unless a
completed run of that ID exists, in which case it is reused. Returns the run
ID; throws when the scenario file is missing, when the run directory exists
without `RUN_COMPLETE`, or when the run does not complete.
"""
function ensure_run(prefix, entry)
    id = run_id(prefix, entry.scenario)
    dir = run_directory(id)
    config = joinpath("scenarios", entry.scenario * ".toml")
    isfile(joinpath(REPO, config)) ||
        error("[ASSETS] Scenario file $config not found under $REPO.")
    if isfile(joinpath(dir, "RUN_COMPLETE"))
        println("[ASSETS] Reusing completed run $id.")
        return id
    end
    if isdir(dir) && !isempty(readdir(dir))
        error(
            "[ASSETS] Run directory $dir exists without RUN_COMPLETE. Purge it with " *
            "scripts/maintenance/cleanup.jl or choose another prefix.",
        )
    end
    if first(Sys.loadavg()) > LOAD_WARN
        @warn "[ASSETS] The host is loaded; the run is paced against wall time, so the " *
              "realized totals will fall below those of an idle host." load_average =
            first(Sys.loadavg())
    end
    ensure_external_series(entry)
    println("[ASSETS] Running $config as $id ...")
    script = joinpath("scripts", "run_full_sim.jl")
    run(Cmd(`$(julia_command()) $script $id $config`; dir = REPO))
    log_path = joinpath(dir, "supervisor.log")
    isfile(joinpath(dir, "RUN_COMPLETE")) ||
        error("[ASSETS] Run $id did not complete; see $log_path.")
    return id
end

"""
    render_animation(id::String) -> String

Renders the web-profile batch-routing animation of run `id`, replacing an
earlier rendering: the animation is drawn after the run by a script of its
own, so it is always that of the commit recorded under `[render]`. Returns
its path; throws when the renderer does not write it.
"""
function render_animation(id::String)
    path = joinpath(run_directory(id), "plots", WEB_ANIMATION)
    println("[ASSETS] Rendering the web-profile animation of $id ...")
    script = joinpath("scripts", "postprocessing", "generate_gif.jl")
    run(Cmd(`$(julia_command()) $script --web $id`; dir = REPO))
    isfile(path) || error("[ASSETS] Animation of run $id was not written to $path.")
    return path
end

"""
    publish_png(source::String, target::String) -> String

Reduces a PNG run product to [`PNG_WIDTH_PX`](@ref) pixels wide with
ImageMagick, in full color: a reduced palette bands the fading wash of the
recovery ramps. Returns `target`; throws when `source` is missing.
"""
function publish_png(source::String, target::String)
    isfile(source) || error("[ASSETS] Missing run product $source.")
    mkpath(dirname(target))
    width = "$(PNG_WIDTH_PX)x"
    run(`magick $source -resize $width -strip -define png:compression-level=9 $target`)
    return target
end

"""
    sha256_prefix(path::String) -> String

First 16 hexadecimal characters of the SHA-256 digest of the file at `path`.
"""
sha256_prefix(path::String) = bytes2hex(open(sha256, path))[1:16]

"""
    asset_record(id::String, source::String, target::String) -> Dict{String,Any}

Provenance entry of one published file: producing run, source path relative
to the repository, size, and digest prefix; PNG targets also carry their width.
"""
function asset_record(id::String, source::String, target::String)
    record = Dict{String,Any}(
        "run_id" => id,
        "source" => replace(relpath(source, REPO), '\\' => '/'),
        "bytes" => filesize(target),
        "sha256_prefix" => sha256_prefix(target),
    )
    endswith(target, ".png") && (record["width_px"] = PNG_WIDTH_PX)
    return record
end

"""
    profile_totals(dir::String) -> Dict{String,Any}

Realized totals of a run from the first and last data rows of its
`mission_profile.csv`, with the wall-clock date of the last row under
`"wall_date"`. Throws when the profile holds no data row or lacks a column.
"""
function profile_totals(dir::String)
    path = joinpath(dir, "mission_profile.csv")
    lines = readlines(path)
    filter!(!isempty, lines)
    length(lines) >= 2 || error("[ASSETS] $path holds no data row.")
    header = split(lines[1], ',')
    first_row = split(lines[2], ',')
    last_row = split(lines[end], ',')
    function field(row, name)
        index = findfirst(==(name), header)
        index === nothing && error("[ASSETS] Column $name missing from $path.")
        return row[index]
    end
    value(row, name) = parse(Int, field(row, name))
    return Dict{String,Any}(
        "ground_total" => value(last_row, "Ground_Total"),
        "ground_live" => value(last_row, "Ground_Live"),
        "ground_archive" => value(last_row, "Ground_Arch"),
        "lost_count" => value(last_row, "Lost_Count"),
        "retry_count" => value(last_row, "Retry_Count"),
        "onboard_buffer_start" => value(first_row, "Onboard_Buffer"),
        "onboard_buffer_end" => value(last_row, "Onboard_Buffer"),
        "profile_rows" => length(lines) - 1,
        "wall_date" => String(first(field(last_row, "WallTime"), 10)),
    )
end

"""
    delivery_totals(dir::String, requirement_hours::Real) -> Dict{String,Any}

Generated batches of a run and those on the ground within `requirement_hours`
of their measurement, from its `delivery_delay.csv`. Empty when the run did
not write the table; throws when the table lacks the delay column.
"""
function delivery_totals(dir::String, requirement_hours::Real)
    path = joinpath(dir, "delivery_delay.csv")
    isfile(path) || return Dict{String,Any}()
    lines = readlines(path)
    filter!(!isempty, lines)
    column = findfirst(==("Delay_Hours"), split(lines[1], ','))
    column === nothing && error("[ASSETS] Column Delay_Hours missing from $path.")
    delays = [split(line, ',')[column] for line in lines[2:end]]
    delivered = [parse(Float64, delay) for delay in delays if !isempty(delay)]
    return Dict{String,Any}(
        "generated" => length(delays),
        "delivered_within_requirement" => count(<=(requirement_hours), delivered),
        "delivery_requirement_hours" => Float64(requirement_hours),
    )
end

"""
    run_record(id::String, entry) -> Dict{String,Any}

Provenance entry of one run: scenario, command, commit and versions, config
digest, date, mission span, platform fingerprint, and realized totals, taken
from the run's `config_snapshot.toml`, `mission_profile.csv`, and
`delivery_delay.csv`. Host name and `versioninfo` are not copied.
"""
function run_record(id::String, entry)
    dir = run_directory(id)
    snapshot = TOML.parsefile(joinpath(dir, "config_snapshot.toml"))
    provenance = get(snapshot, "provenance", Dict{String,Any}())
    platform = get(provenance, "platform", Dict{String,Any}())
    simulation = get(snapshot, "simulation", Dict{String,Any}())
    post_processing = get(snapshot, "post_processing", Dict{String,Any}())
    totals = profile_totals(dir)
    date = pop!(totals, "wall_date")
    merge!(
        totals,
        delivery_totals(dir, get(post_processing, "delivery_requirement_hours", 24.0)),
    )
    mission_days =
        get(simulation, "mission_wall_seconds", 0.0) * get(simulation, "speed_up", 0.0) /
        86400
    platform_keys = (
        "os",
        "cpu_model",
        "logical_cores",
        "total_memory_gb",
        "julia_threads",
        "blas_threads",
    )
    return Dict{String,Any}(
        "scenario" => "scenarios/$(entry.scenario).toml",
        "command" =>
            "julia --threads=$(RUN_THREADS) scripts/run_full_sim.jl $id " *
            "scenarios/$(entry.scenario).toml",
        "commit" => get(platform, "git_commit", ""),
        "git_dirty" => get(platform, "git_dirty", false),
        "package_version" => get(platform, "package_version", ""),
        "julia_version" => get(platform, "julia_version", ""),
        "config_sha256" => get(provenance, "config_sha256", ""),
        "date" => date,
        "mission_days" => round(mission_days, digits = 3),
        "platform" => Dict{String,Any}(
            key => platform[key] for key in platform_keys if haskey(platform, key)
        ),
        "realized" => totals,
    )
end

"""
    image_tool() -> String

Name and version of the ImageMagick installation, e.g. `"ImageMagick 7.1.2-32"`.
Throws when `magick` is not on the PATH.
"""
function image_tool()
    Sys.which("magick") === nothing && error(
        "[ASSETS] ImageMagick (magick) is not on the PATH; it reduces the run products " *
        "to the published size.",
    )
    tokens = split(first(split(read(`magick -version`, String), '\n')))
    return join(tokens[2:3], " ")
end

"""
    write_provenance(path::String, record::Dict{String,Any}) -> String

Writes the provenance record as TOML with sorted keys below a fixed comment
header. Returns `path`.
"""
function write_provenance(path::String, record::Dict{String,Any})
    open(path, "w") do io
        print(
            io,
            """
            # Provenance of the figures shown in README.md and in the manual. Written by
            # docs/render_assets.jl, which runs every listed scenario, reduces the run
            # products to the published size, and records each run and each file here.
            # The realized totals depend on how much mission time the host completes
            # within the configured wall-clock budget, so a re-run on another machine
            # reproduces the regimes and the figures, not the counts to the batch; the
            # platform of each run is stated with it.
            """,
        )
        TOML.print(io, record; sorted = true)
    end
    return path
end

"""
    main(args) -> Nothing

Runs the gallery scenarios in order, publishes the listed run products under
[`ASSET_DIR`](@ref), warns about gallery files the table does not produce, and
writes `PROVENANCE.toml`. Throws on a malformed argument list or prefix.
"""
function main(args)
    length(args) <= 1 || error("usage: julia docs/render_assets.jl [PREFIX]")
    prefix = isempty(args) ? DEFAULT_PREFIX : args[1]
    occursin(r"^[A-Za-z0-9_.-]+$", prefix) || throw(
        ArgumentError(
            "Run-ID prefix \"$prefix\" may hold letters, digits, '_', '.', and '-' only.",
        ),
    )
    tool = image_tool()

    runs = Dict{String,Any}()
    assets = Dict{String,Any}()
    for entry in GALLERY
        id = ensure_run(prefix, entry)
        plots = joinpath(run_directory(id), "plots")
        for stem in entry.figures
            name = "$(entry.scenario)_$(stem).png"
            target = joinpath(ASSET_DIR, GALLERY_SUBDIR, name)
            source = joinpath(plots, stem * ".png")
            publish_png(source, target)
            assets["$(GALLERY_SUBDIR)/$name"] = asset_record(id, source, target)
        end
        if entry.animation
            source = render_animation(id)
            name = "$(entry.scenario)_$(WEB_ANIMATION)"
            target = joinpath(ASSET_DIR, GALLERY_SUBDIR, name)
            mkpath(dirname(target))
            cp(source, target; force = true)
            assets["$(GALLERY_SUBDIR)/$name"] = asset_record(id, source, target)
        end
        runs[id] = run_record(id, entry)
    end

    gallery_dir = joinpath(ASSET_DIR, GALLERY_SUBDIR)
    for name in readdir(gallery_dir)
        path = joinpath(gallery_dir, name)
        isfile(path) || continue
        haskey(assets, "$(GALLERY_SUBDIR)/$name") && continue
        @warn "[ASSETS] File not produced by the gallery table; remove it if it is no " *
              "longer referenced." file = replace(relpath(path, REPO), '\\' => '/')
    end

    # The figures are drawn during each run, at the commit its entry records;
    # the animations and the reduction happen here, at this commit.
    code_changes = DeepSpaceTelemetry.TelemetryCore.git_output(
        `status --porcelain --untracked-files=no -- src scripts`,
    )
    record = Dict{String,Any}(
        "render" => Dict{String,Any}(
            "date" => Dates.format(Dates.today(), "yyyy-mm-dd"),
            "command" => "julia docs/render_assets.jl $prefix",
            "commit" => DeepSpaceTelemetry.TelemetryCore.git_commit(),
            "code_dirty" => !isempty(something(code_changes, "")),
            "image_tool" => tool,
            "png_transform" =>
                "magick <source> -resize $(PNG_WIDTH_PX)x -strip " *
                "-define png:compression-level=9 <target>",
            "gif_transform" => "none; the --web rendering profile writes the published size directly",
        ),
        "runs" => runs,
        "assets" => assets,
    )
    provenance_path = write_provenance(joinpath(ASSET_DIR, "PROVENANCE.toml"), record)

    total_bytes = 0
    for key in sort!(collect(keys(assets)))
        bytes = assets[key]["bytes"]
        total_bytes += bytes
        println("[ASSETS] ", rpad(key, 64), round(bytes / 1000, digits = 1), " kB")
    end
    println(
        "[ASSETS] Total ",
        round(total_bytes / 1e6, digits = 2),
        " MB; provenance in ",
        replace(relpath(provenance_path, REPO), '\\' => '/'),
        ".",
    )
    return nothing
end

main(ARGS)
