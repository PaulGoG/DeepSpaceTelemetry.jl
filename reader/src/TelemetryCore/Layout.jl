# --- Constants and run paths ---
"""
    C_LIGHT

Speed of light in vacuum [m s⁻¹].
"""
const C_LIGHT = 2.99792458e8

"""
    PROJECT_ROOT

Absolute path of the package root (a `Ref`), which holds `config.toml`,
`scenarios/` and `data/`. `physics.external_data_path` resolves against it;
`contacts.schedule_csv` and the config file resolve against the current
directory first, then against it. A run records the root's source identity.
`DeepSpaceTelemetry` sets it to its own root when it loads; on its own, the
reader package points it at the reader's root.
"""
const PROJECT_ROOT = Ref{String}(dirname(dirname(@__DIR__)))

"""
    DATA_ROOT

Default base directory for run storage (a `Ref`; default
[`default_data_root`](@ref) of the package root): the data root of the entry points
(`Supervisor.run_mission`, the scripts, `RunAdapter.open_run` by run ID)
when none is given. The components take their run directory explicitly.
"""
const DATA_ROOT = Ref{String}("")

"""
    DATA_ROOT_VARIABLE

The environment variable that names the default data root
([`default_data_root`](@ref)): `DEEPSPACETELEMETRY_DATA`.
"""
const DATA_ROOT_VARIABLE = "DEEPSPACETELEMETRY_DATA"

"""
    default_data_root(root::AbstractString) -> String

The data root a package rooted at `root` uses by default: the directory
named by the environment variable [`DATA_ROOT_VARIABLE`](@ref) when it is set
and not empty (made absolute), else `<root>/data`. A container or a cluster
job sets the variable to a mounted volume.
"""
function default_data_root(root::AbstractString)
    dir = get(ENV, DATA_ROOT_VARIABLE, "")
    return isempty(dir) ? joinpath(root, "data") : abspath(dir)
end

function __init__()
    # Runtime (not precompile-time) initialization; tests and embedding
    # applications may redirect after loading.
    DATA_ROOT[] = default_data_root(PROJECT_ROOT[])
    return nothing
end

"""
    run_directory(run_id::String, data_root::String = DATA_ROOT[]) -> String

Run-directory path `<data_root>/runs/<run_id>`.
"""
run_directory(run_id::String, data_root::String = DATA_ROOT[]) =
    joinpath(data_root, "runs", run_id)

"""
    checked_run_dir(run_dir::String) -> String

`run_dir` when it is an absolute path, else an `ArgumentError`: the
components address a run by its directory, and a bare run ID resolves
through [`run_directory`](@ref).
"""
function checked_run_dir(run_dir::String)
    isabspath(run_dir) || throw(
        ArgumentError(
            "[RUN] Expected an absolute run-directory path, got $(repr(run_dir)); resolve a run ID with TelemetryCore.run_directory.",
        ),
    )
    return run_dir
end

"""
    runs_root() -> String

Directory holding every run directory (`<DATA_ROOT>/runs`).
"""
runs_root() = joinpath(DATA_ROOT[], "runs")

"""
    latest_run_id() -> Union{Nothing, String}

ID of the most recently modified run directory under [`runs_root`](@ref) that
carries a `config_snapshot.toml`, or `nothing` when no run exists. Used by
the post-processing scripts when no run ID is given on the command line.
"""
function latest_run_id()
    root = runs_root()
    isdir(root) || return nothing
    runs = filter(readdir(root)) do name
        isfile(joinpath(root, name, "config_snapshot.toml"))
    end
    isempty(runs) && return nothing
    return last(sort(runs; by = name -> mtime(joinpath(root, name))))
end

# --- Batch wire format ---
# Batch directory names, as used by both components, the replay, and the viewer.

"""
    batch_name(id::Integer, live::Bool) -> String

Directory name of batch `id`: `LIVE_batch_<id>` for a batch finalized while
the link was transmittable, `ARCH_batch_<id>` otherwise.

# Examples
```jldoctest
julia> TelemetryCore.batch_name(42, true)
"LIVE_batch_42"

julia> TelemetryCore.batch_name(42, false)
"ARCH_batch_42"
```
"""
batch_name(id::Integer, live::Bool) = string(live ? "LIVE_batch_" : "ARCH_batch_", id)

"""
    batch_id(name::AbstractString) -> Int

Numeric ID parsed from a batch directory name (the trailing `_<id>` field);
`0` for a name that does not carry one, such as a stray directory entry.

# Examples
```jldoctest
julia> TelemetryCore.batch_id("LIVE_batch_42")
42

julia> TelemetryCore.batch_id("stray_entry")
0
```
"""
batch_id(name::AbstractString) = something(tryparse(Int, String(last(split(name, '_')))), 0)

"""
    is_live_batch(name::AbstractString) -> Bool

`true` for a `LIVE_batch_<id>` directory name (finalized while the link was
transmittable).

# Examples
```jldoctest
julia> TelemetryCore.is_live_batch("LIVE_batch_7"), TelemetryCore.is_live_batch("ARCH_batch_7")
(true, false)
```
"""
is_live_batch(name::AbstractString) = startswith(name, "LIVE_batch_")

"""
    is_archive_batch(name::AbstractString) -> Bool

`true` for an `ARCH_batch_<id>` directory name (blind-spot or blackout
generation, delivered by the LIFO backfill).
"""
is_archive_batch(name::AbstractString) = startswith(name, "ARCH_batch_")

"""
    is_batch_name(name::AbstractString) -> Bool

`true` for either batch class; `false` for any other directory entry.
"""
is_batch_name(name::AbstractString) = is_live_batch(name) || is_archive_batch(name)
