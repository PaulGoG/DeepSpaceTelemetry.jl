# --- Run Management ---
"""
    config_sha256(cfg::AbstractDict) -> String

SHA-256, as 64 hex digits, of the configuration printed as sorted TOML
without its `provenance` section: the identity of the parameters alone,
the same on every host and for every run of one configuration.
"""
function config_sha256(cfg::AbstractDict)
    parameters =
        Dict{String,Any}(String(k) => v for (k, v) in cfg if String(k) != "provenance")
    return bytes2hex(sha256(sprint(io -> TOML.print(io, parameters; sorted = true))))
end

"""
    generate_run_id(cfg::AbstractDict) -> String

Run identifier `RUN_cfg=<8 hex>_pid=<pid>_t=<yyyymmdd_HHMMSS>`: the first
eight hex digits of [`config_sha256`](@ref), the process id, and the
wall-clock instant — key=value fields in alphabetical order, the layout of
DrWatson's `savename`. The hash makes the runs of one configuration
recognizable by name; the process id and the instant keep the identifier
unique.
"""
function generate_run_id(cfg::AbstractDict)
    return string(
        "RUN_cfg=",
        first(config_sha256(cfg), 8),
        "_pid=",
        getpid(),
        "_t=",
        Dates.format(now(), "yyyymmdd_HHMMSS"),
    )
end

"""
    platform_provenance() -> Dict{String,Any}

Hardware and runtime fingerprint stamped into every run's
`config_snapshot.toml` under `[provenance.platform]`: hostname, OS kernel
and architecture, CPU model and logical core count, total memory, Julia
version and `versioninfo()` report, thread and BLAS-thread counts, the
package version, and the source identity of [`source_identity`](@ref)
(`identity_source`, `git_commit`, `git_tree_sha1`, `git_dirty`, `repo_url`,
`repo_rev`), valid for a git checkout and a Pkg-installed copy alike. The
manifest is recorded beside the snapshot by [`save_manifest_snapshot`](@ref).
There are no GPU fields: the pipeline is I/O- and event-loop-bound and uses
no GPU backend.
"""
function platform_provenance()
    cpu = Sys.cpu_info()
    provenance = Dict{String,Any}(
        "package_version" => string(pkgversion(TelemetryCore)),
        "hostname" => Base.Libc.gethostname(),
        "os" => string(Sys.KERNEL, " ", Sys.MACHINE),
        "cpu_model" => isempty(cpu) ? "unknown" : cpu[1].model,
        "logical_cores" => Sys.CPU_THREADS,
        "total_memory_gb" => round(Sys.total_memory() / 1024^3; digits = 2),
        "julia_version" => string(VERSION),
        "versioninfo" => sprint(InteractiveUtils.versioninfo),
        "julia_threads" => Threads.nthreads(),
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
    )
    for (key, value) in pairs(source_identity())
        provenance[String(key)] = value
    end
    return provenance
end

"""
    source_identity(root = PROJECT_ROOT[]; manifest = active_manifest_path()) -> NamedTuple

The identity of the package source at `root`, stamped into
`[provenance.platform]` and copied into `descriptor.toml`:

- `identity_source` — how it was determined: `"work_tree"` when `root` is
  the top level of a git work tree ([`git_work_tree`](@ref)); `"manifest"`
  for an installed copy whose package UUID has an entry with a
  `git-tree-sha1` in the manifest `manifest` (the active environment's by
  default, [`active_manifest_path`](@ref)); `"directory"` otherwise.
- `git_commit` — the `HEAD` commit of the work tree; for an installed copy
  the entry's `repo-rev` when it is a full 40-digit commit hash, as in a
  `[sources]` pin by commit; empty otherwise (a branch or tag, a registry
  install, a bare directory).
- `git_tree_sha1` — the git tree hash of the source: `HEAD^{tree}` of the
  work tree, the entry's `git-tree-sha1`, or the hash of the directory
  itself ([`git_tree_sha1`](@ref)). Never empty, and the same value for the
  same content however the package was obtained.
- `git_dirty` — whether the code at `root` differs from that identity:
  uncommitted changes to tracked files of the work tree, or an installed
  directory whose tree hash differs from the entry's (with a warning).
  `false` for `"directory"`, whose identity is the content itself.
- `repo_url`, `repo_rev` — the entry's `repo-url` and `repo-rev`; empty
  unless `identity_source == "manifest"` and the copy was added by URL.

The directory hash leaves out `.git` and the data root ([`DATA_ROOT`](@ref))
when it lies inside `root`.

# Example
```julia
id = TelemetryCore.source_identity()
id.git_tree_sha1   # 40 hexadecimal digits, for a checkout and an installed copy alike
```
"""
function source_identity(
    root::AbstractString = PROJECT_ROOT[];
    manifest::Union{AbstractString,Nothing} = active_manifest_path(),
)
    isdir(root) || throw(ArgumentError("[RUN] No package directory $root."))
    if git_work_tree(root)
        lines = split(something(git_output(`rev-parse HEAD 'HEAD^{tree}'`; root), ""), '\n')
        length(lines) == 2 || throw(
            ErrorException("[RUN] git rev-parse returned no commit and tree for $root."),
        )
        # The work tree was established just above; git_dirty(root) would test it again.
        status = git_output(`status --porcelain --untracked-files=no`; root)
        return (
            identity_source = "work_tree",
            git_commit = String(strip(lines[1])),
            git_tree_sha1 = String(strip(lines[2])),
            git_dirty = !isempty(something(status, "")),
            repo_url = "",
            repo_rev = "",
        )
    end
    content = git_tree_sha1(root; exclude = [DATA_ROOT[]])
    entry = manifest_entry(root, manifest)
    if entry === nothing || isempty(string(get(entry, "git-tree-sha1", "")))
        return (
            identity_source = "directory",
            git_commit = "",
            git_tree_sha1 = content,
            git_dirty = false,
            repo_url = "",
            repo_rev = "",
        )
    end
    recorded = string(entry["git-tree-sha1"])
    rev = string(get(entry, "repo-rev", ""))
    dirty = content != recorded
    dirty &&
        @warn "[RUN] The package directory $root does not match its manifest entry (git-tree-sha1 $recorded, directory $content): recorded as git_dirty."
    return (
        identity_source = "manifest",
        git_commit = occursin(r"^[0-9a-f]{40}$", rev) ? rev : "",
        git_tree_sha1 = recorded,
        git_dirty = dirty,
        repo_url = string(get(entry, "repo-url", "")),
        repo_rev = rev,
    )
end

"""
    manifest_beside(project::AbstractString) -> Union{String,Nothing}

The manifest next to the project file `project`, the version-specific
`Manifest-v<major>.<minor>.toml` first, then `Manifest.toml`; `nothing`
when neither exists. The fallback of [`active_manifest_path`](@ref) for a
Julia without `Base.project_file_manifest_path`.
"""
function manifest_beside(project::AbstractString)
    dir = dirname(project)
    for name in ("Manifest-v$(VERSION.major).$(VERSION.minor).toml", "Manifest.toml")
        path = joinpath(dir, name)
        isfile(path) && return path
    end
    return nothing
end

"""
    active_manifest_path(project = Base.active_project()) -> Union{String,Nothing}

The manifest of the environment whose project file is `project`, resolved
as Julia's code loading resolves it (a workspace root, a `manifest` key,
the version-specific `Manifest-vX.Y.toml` before `Manifest.toml`), or
`nothing` when there is no project or no manifest. On a Julia without the
internal `Base.project_file_manifest_path` it falls back to the manifest
next to the project file ([`manifest_beside`](@ref)).
"""
function active_manifest_path(
    project::Union{AbstractString,Nothing} = Base.active_project(),
)
    project === nothing && return nothing
    project = String(project)
    if isdefined(Base, :project_file_manifest_path)
        return Base.project_file_manifest_path(project)
    end
    return manifest_beside(project)
end

"""
    manifest_entry(root, manifest) -> Union{Dict{String,Any},Nothing}

The entry of the manifest file `manifest` for the package whose project file
lies at `root`, matched by name and UUID, or `nothing` when either file or
the entry is absent. Reads both the current manifest format (`[[deps.Name]]`)
and the format before Julia 1.7 (`[[Name]]`).
"""
function manifest_entry(root::AbstractString, manifest::Union{AbstractString,Nothing})
    manifest === nothing && return nothing
    projects = joinpath.(root, ("JuliaProject.toml", "Project.toml"))
    found = findfirst(isfile, projects)
    (found === nothing || !isfile(manifest)) && return nothing
    project = TOML.parsefile(projects[found])
    name = get(project, "name", nothing)
    uuid = tryparse(Base.UUID, string(get(project, "uuid", "")))
    (name isa String && uuid !== nothing) || return nothing
    content = TOML.parsefile(manifest)
    deps = haskey(content, "manifest_format") ? get(content, "deps", Dict()) : content
    for entry in get(deps, name, Any[])
        entry isa Dict{String,Any} || continue
        tryparse(Base.UUID, string(get(entry, "uuid", ""))) == uuid && return entry
    end
    return nothing
end

"""
    git_tree_sha1(dir::AbstractString; exclude = String[]) -> String

The git tree hash (40 hexadecimal digits) of the directory `dir` as git
would record it if every file under it were committed: entries in git's
order, modes `100644`, `100755` (owner-executable), `120000` (symbolic link,
hashed as its target) and `40000` (directory), empty directories and `.git`
entries left out, as `git write-tree` and Pkg do. The hash of an unmodified
installed copy therefore equals the `git-tree-sha1` of its manifest entry
and `git rev-parse <commit>^{tree}` of the commit it was installed from.
The paths in `exclude` are left out with everything under them.
"""
function git_tree_sha1(
    dir::AbstractString;
    exclude::AbstractVector{<:AbstractString} = String[],
)
    isdir(dir) || throw(ArgumentError("[RUN] No directory $dir to hash."))
    excluded = Set{String}(normpath(abspath(p)) for p in exclude if !isempty(p))
    entries = git_tree_entries(normpath(abspath(dir)), excluded)
    return bytes2hex(git_tree_digest(entries))
end

"""
    git_tree_entries(dir, excluded) -> Vector{Tuple{String,String,Vector{UInt8}}}

The `(mode, name, object hash)` entries of the git tree of `dir`, in git's
order (a directory sorts as its name followed by `/`).
"""
function git_tree_entries(dir::String, excluded::Set{String})
    entries = Tuple{String,String,Vector{UInt8}}[]
    for name in readdir(dir)
        path = joinpath(dir, name)
        (name == ".git" || path in excluded) && continue
        if islink(path)
            push!(entries, ("120000", name, git_blob_digest(codeunits(readlink(path)))))
        elseif isdir(path)
            children = git_tree_entries(path, excluded)
            isempty(children) || push!(entries, ("40000", name, git_tree_digest(children)))
        elseif isfile(path)
            executable = @static if Sys.iswindows()
                Sys.isexecutable(path)
            else
                !iszero(filemode(path) & 0o100)
            end
            push!(entries, (executable ? "100755" : "100644", name, git_blob_digest(path)))
        end
    end
    sort!(entries; by = e -> e[1] == "40000" ? string(e[2], '/') : e[2])
    return entries
end

"""
    git_tree_digest(entries) -> Vector{UInt8}

The SHA-1 of the git tree object made of `entries` ([`git_tree_entries`](@ref)).
"""
function git_tree_digest(entries::Vector{Tuple{String,String,Vector{UInt8}}})
    body = IOBuffer()
    for (mode, name, digest) in entries
        write(body, mode, ' ', name, '\0', digest)
    end
    bytes = take!(body)
    context = SHA.SHA1_CTX()
    SHA.update!(context, codeunits(string("tree ", length(bytes), '\0')))
    SHA.update!(context, bytes)
    return SHA.digest!(context)
end

"""
    git_blob_digest(source) -> Vector{UInt8}

The SHA-1 of the git blob object holding `source`: the bytes of a file path,
read in chunks, or a byte vector (the target of a symbolic link).
"""
function git_blob_digest(bytes::AbstractVector{UInt8})
    context = SHA.SHA1_CTX()
    SHA.update!(context, codeunits(string("blob ", length(bytes), '\0')))
    SHA.update!(context, bytes)
    return SHA.digest!(context)
end

function git_blob_digest(path::String)
    context = SHA.SHA1_CTX()
    SHA.update!(context, codeunits(string("blob ", filesize(path), '\0')))
    buffer = Vector{UInt8}(undef, 1 << 16)
    open(path) do io
        while !eof(io)
            n = readbytes!(io, buffer)
            SHA.update!(context, buffer, n)
        end
    end
    return SHA.digest!(context)
end

"""
    git_work_tree(root = PROJECT_ROOT[]) -> Bool

Whether `root` is the top level of a git work tree with a commit at `HEAD`;
`false` when git is not installed. A directory inside another repository
does not count, since an installed copy under a version-controlled depot
would otherwise be given that repository's commit.
"""
function git_work_tree(root::AbstractString = PROJECT_ROOT[])
    top = git_output(`rev-parse --show-toplevel`; root)
    (top === nothing || isempty(top) || realpath(top) != realpath(root)) && return false
    return git_output(`rev-parse --verify --quiet HEAD`; root) !== nothing
end

"""
    git_commit(root = PROJECT_ROOT[]) -> String

The `HEAD` commit of the git work tree at `root`, or `""` when `root` is not
one ([`git_work_tree`](@ref)). [`source_identity`](@ref) covers installed
copies as well.
"""
function git_commit(root::AbstractString = PROJECT_ROOT[])
    git_work_tree(root) || return ""
    return something(git_output(`rev-parse HEAD`; root), "")
end

"""
    git_dirty(root = PROJECT_ROOT[]) -> Bool

Whether the git work tree at `root` carries uncommitted changes to tracked
files (`git status --porcelain --untracked-files=no`); `false` when `root` is
not a work tree ([`git_work_tree`](@ref)). A run made from a dirty tree is
not reproducible from its recorded commit alone.
"""
function git_dirty(root::AbstractString = PROJECT_ROOT[])
    git_work_tree(root) || return false
    status = git_output(`status --porcelain --untracked-files=no`; root)
    return !isempty(something(status, ""))
end

"""
    git_output(arguments::Cmd; root = PROJECT_ROOT[]) -> Union{String,Nothing}

Standard output of `git -C <root> <arguments>`, stripped, or `nothing` when
git is not installed or the command fails (no repository).
"""
function git_output(arguments::Cmd; root::AbstractString = PROJECT_ROOT[])
    try
        command = `git -C $root $arguments`
        return String(strip(read(pipeline(command; stderr = devnull), String)))
    catch e
        e isa Union{Base.IOError,ProcessFailedException} || rethrow()
        return nothing
    end
end

"""
    save_manifest_snapshot(run_dir::String) -> Union{String,Nothing}

Copies the manifest of the active environment ([`active_manifest_path`](@ref))
to `<run_dir>/manifest_snapshot.toml`, so the run records the dependency
versions it was resolved on; manifests are not tracked in the repository.
Returns the snapshot path, or `nothing` with a warning when the active
environment has no manifest.
"""
function save_manifest_snapshot(run_dir::String)
    manifest = active_manifest_path()
    if manifest === nothing
        @warn "[RUN] The active environment has no manifest — dependency versions of this run are not recorded."
        return nothing
    end
    snapshot_path = joinpath(run_dir, "manifest_snapshot.toml")
    backup_existing(snapshot_path)
    cp(manifest, snapshot_path)
    return snapshot_path
end

"""
    setup_run_dir(run_id::String; cfg = nothing) -> String

Creates and returns the run directory of `run_id` with its subdirectories
`onboard`, `link`, `ground`, `lost`, `plots`, and `masks`; a directory under
the same run ID that holds anything but dotfiles is rejected with an
`ArgumentError`. Given the parsed configuration `cfg`, it writes
`config_snapshot.toml` (rotating an existing one, [`backup_existing`](@ref))
so that the run's parameters survive later edits of `config.toml`. The
snapshot adds the [`platform_provenance`](@ref) fingerprint under
`[provenance.platform]` and the parameter hash [`config_sha256`](@ref) at
`provenance.config_sha256`; the manifest of the active environment is
copied beside it ([`save_manifest_snapshot`](@ref)).
"""
function setup_run_dir(run_id::String; cfg::Union{AbstractDict,Nothing} = nothing)
    base_dir = run_directory(run_id)
    # Run-ID reuse guard (silent-failure mode): a reused ID would interleave
    # two missions' rows in mission_profile.csv and truncate the prior logs.
    if isdir(base_dir) && !isempty(filter(f -> !startswith(f, "."), readdir(base_dir)))
        throw(
            ArgumentError(
                "[RUN] Run directory $base_dir already exists and is non-empty — run IDs must be unique. Choose a new run ID or purge the previous run (scripts/maintenance/cleanup.jl).",
            ),
        )
    end
    paths = [
        joinpath(base_dir, "onboard"),
        joinpath(base_dir, "link"),
        joinpath(base_dir, "ground"),
        joinpath(base_dir, "lost"),
        joinpath(base_dir, "plots"),
        joinpath(base_dir, "masks"),
    ]
    foreach(mkpath, paths)
    if cfg !== nothing
        # Shallow-copied so the platform stamp never mutates the caller's
        # configuration dictionary.
        snapshot = Dict{String,Any}(cfg)
        prov_in = get(snapshot, "provenance", Dict{String,Any}())
        prov = prov_in isa AbstractDict ? Dict{String,Any}(prov_in) : Dict{String,Any}()
        prov["platform"] = platform_provenance()
        prov["config_sha256"] = config_sha256(cfg)
        snapshot["provenance"] = prov
        snapshot_path = joinpath(base_dir, "config_snapshot.toml")
        backup_existing(snapshot_path)
        open(snapshot_path, "w") do io
            TOML.print(io, snapshot)
        end
        save_manifest_snapshot(base_dir)
    end
    return base_dir
end
