# The source identity of a run: the git tree hash against git and Pkg, the
# three ways an identity is determined (work tree, manifest entry of an
# installed copy, bare directory), a copy inside a foreign repository, the
# data root left out of a directory hash, and the manifest resolution.

import Pkg

const FIXTURE_GIT = `git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false`

has_git() = TelemetryCore.git_output(`--version`) !== nothing

"""
    write_tree_fixture(dir)

Fills `dir` with the cases git's tree order and modes distinguish: a file
sorting before a directory of the same stem (`a.txt`, `.` < `/`) and one
after it (`a0`), a nested directory, an empty directory (left out), an
empty file, binary content, and off Windows an executable and a symbolic
link.
"""
function write_tree_fixture(dir::String)
    mkpath(joinpath(dir, "a", "b"))
    write(joinpath(dir, "a", "b", "c.txt"), "nested\n")
    write(joinpath(dir, "a.txt"), "before the directory a\n")
    write(joinpath(dir, "a-b"), "dash\n")
    write(joinpath(dir, "a0"), "after the directory a\n")
    mkpath(joinpath(dir, "empty"))
    write(joinpath(dir, "zero"), "")
    write(joinpath(dir, "bytes.bin"), UInt8[0x00, 0xff, 0x0a, 0x0d])
    if !Sys.iswindows()
        write(joinpath(dir, "run.sh"), "#!/bin/sh\n")
        chmod(joinpath(dir, "run.sh"), 0o755)
        symlink("a.txt", joinpath(dir, "link"))
    end
    return dir
end

"""
    write_manifest(path, uuid, entry; format = "2.0")

Writes a manifest holding one entry for this package, `entry` merged over
its name and UUID, in the current format or (`format = "1.0"`) the format
before Julia 1.7.
"""
function write_manifest(
    path::String,
    uuid::Base.UUID,
    entry::Dict{String,Any};
    format = "2.0",
)
    record = merge(Dict{String,Any}("uuid" => string(uuid), "version" => "2.6.1"), entry)
    content =
        format == "2.0" ?
        Dict{String,Any}(
            "julia_version" => string(VERSION),
            "manifest_format" => "2.0",
            "deps" => Dict{String,Any}("DeepSpaceTelemetry" => [record]),
        ) : Dict{String,Any}("DeepSpaceTelemetry" => [record])
    open(io -> TOML.print(io, content), path, "w")
    return path
end

@testset "Source identity" begin
    # The tree hash is git's: equal to Pkg's for the same directory, and to
    # `git write-tree` where file modes mean the same to both.
    fixture = write_tree_fixture(mktempdir())
    tree = TelemetryCore.git_tree_sha1(fixture)
    @test occursin(r"^[0-9a-f]{40}$", tree)
    @test tree == bytes2hex(Pkg.GitTools.tree_hash(fixture))
    if has_git() && !Sys.iswindows()
        run(`git -C $fixture init -q`)
        run(`git -C $fixture add -A`)
        @test tree == readchomp(`git -C $fixture write-tree`)
        @test TelemetryCore.git_tree_sha1(fixture) == tree   # .git left out
    end
    @test TelemetryCore.git_tree_sha1(mktempdir()) ==
          "4b825dc642cb6eb9a060e54bf8d69288fbee4904"        # git's empty tree
    @test_throws ArgumentError TelemetryCore.git_tree_sha1(joinpath(fixture, "absent"))
    without_a = TelemetryCore.git_tree_sha1(fixture; exclude = [joinpath(fixture, "a")])
    rm(joinpath(fixture, "a"); recursive = true)
    @test without_a == TelemetryCore.git_tree_sha1(fixture) != tree

    # The development checkout: the identity is git's.
    if TelemetryCore.git_work_tree()
        id = TelemetryCore.source_identity()
        @test id.identity_source == "work_tree"
        @test id.git_commit == TelemetryCore.git_output(`rev-parse HEAD`)
        @test id.git_tree_sha1 == TelemetryCore.git_output(`rev-parse 'HEAD^{tree}'`)
        @test id.git_dirty == TelemetryCore.git_dirty()
        @test id.repo_url == "" && id.repo_rev == ""
    end
    # However the package was obtained, the identity is never empty.
    @test occursin(r"^[0-9a-f]{40}$", TelemetryCore.source_identity().git_tree_sha1)

    # An installed copy: the source without .git under
    # <depot>/packages/<name>/<slug>, where Pkg puts it, and the manifest
    # entry of a consumer that pins it by commit through [sources].
    uuid = Base.UUID(
        TOML.parsefile(joinpath(TelemetryCore.PROJECT_ROOT[], "Project.toml"))["uuid"],
    )
    staging = mktempdir()
    for item in ("Project.toml", "src")
        cp(joinpath(TelemetryCore.PROJECT_ROOT[], item), joinpath(staging, item))
    end
    content = TelemetryCore.git_tree_sha1(staging)
    copy = joinpath(
        mktempdir(),
        "packages",
        "DeepSpaceTelemetry",
        Base.version_slug(uuid, Base.SHA1(content)),
    )
    mkpath(dirname(copy))
    mv(staging, copy)
    @test !TelemetryCore.git_work_tree(copy)
    @test TelemetryCore.git_commit(copy) == "" && !TelemetryCore.git_dirty(copy)
    commit = "0123456789abcdef0123456789abcdef01234567"
    url = "https://example.invalid/DeepSpaceTelemetry.jl.git"
    manifest = joinpath(mktempdir(), "Manifest.toml")
    write_manifest(
        manifest,
        uuid,
        Dict{String,Any}(
            "git-tree-sha1" => content,
            "repo-url" => url,
            "repo-rev" => commit,
        ),
    )
    id = TelemetryCore.source_identity(copy; manifest = manifest)
    @test id == (
        identity_source = "manifest",
        git_commit = commit,
        git_tree_sha1 = content,
        git_dirty = false,
        repo_url = url,
        repo_rev = commit,
    )
    # Pinned by branch: no commit, the tree still identifies the content.
    write_manifest(
        manifest,
        uuid,
        Dict{String,Any}(
            "git-tree-sha1" => content,
            "repo-url" => url,
            "repo-rev" => "main",
        ),
    )
    id = TelemetryCore.source_identity(copy; manifest = manifest)
    @test id.git_commit == "" && id.repo_rev == "main" && id.git_tree_sha1 == content
    # From a registry, in the manifest format before Julia 1.7.
    write_manifest(
        manifest,
        uuid,
        Dict{String,Any}("git-tree-sha1" => content);
        format = "1.0",
    )
    id = TelemetryCore.source_identity(copy; manifest = manifest)
    @test id.identity_source == "manifest" && id.git_commit == "" && id.repo_url == ""
    @test id.git_tree_sha1 == content && !id.git_dirty
    # A copy modified after installation keeps the recorded identity, flagged.
    write(joinpath(copy, "src", "patch.jl"), "# local edit\n")
    id =
        @test_logs (:warn, r"does not match its manifest entry") TelemetryCore.source_identity(
            copy;
            manifest = manifest,
        )
    @test id.git_dirty && id.git_tree_sha1 == content
    rm(joinpath(copy, "src", "patch.jl"))
    # No manifest, or none naming this package: the directory's own hash.
    for m in (nothing, write_manifest(manifest, Base.UUID(UInt128(1)), Dict{String,Any}()))
        id = TelemetryCore.source_identity(copy; manifest = m)
        @test id == (
            identity_source = "directory",
            git_commit = "",
            git_tree_sha1 = content,
            git_dirty = false,
            repo_url = "",
            repo_rev = "",
        )
    end
    @test_throws ArgumentError TelemetryCore.source_identity(joinpath(copy, "absent"))

    # Run outputs under the package directory stay out of the hash.
    previous = TelemetryCore.DATA_ROOT[]
    try
        TelemetryCore.DATA_ROOT[] = joinpath(copy, "data")
        mkpath(joinpath(copy, "data", "runs", "RUN_x"))
        write(joinpath(copy, "data", "runs", "RUN_x", "events_rx.csv"), "SimTime\n")
        @test TelemetryCore.source_identity(copy; manifest = nothing).git_tree_sha1 ==
              content
    finally
        TelemetryCore.DATA_ROOT[] = previous
        rm(joinpath(copy, "data"); recursive = true, force = true)
    end

    # A copy inside a foreign repository is not given that repository's commit.
    if has_git()
        outer = mktempdir()
        write(joinpath(outer, "README"), "foreign\n")
        run(`git -C $outer init -q`)
        run(`$FIXTURE_GIT -C $outer add -A`)
        run(`$FIXTURE_GIT -C $outer commit -q -m fixture`)
        nested = joinpath(outer, "vendored")
        cp(copy, nested)
        @test TelemetryCore.git_output(`rev-parse HEAD`; root = nested) !== nothing
        @test !TelemetryCore.git_work_tree(nested)
        @test TelemetryCore.git_commit(nested) == ""
        id = TelemetryCore.source_identity(nested; manifest = nothing)
        @test id.identity_source == "directory" && id.git_tree_sha1 == content
    end

    # The manifest is resolved as code loading resolves it.
    env = mktempdir()
    @test TelemetryCore.active_manifest_path(nothing) === nothing
    write(joinpath(env, "Project.toml"), "[deps]\n")
    @test TelemetryCore.active_manifest_path(joinpath(env, "Project.toml")) === nothing
    write(joinpath(env, "Manifest.toml"), "manifest_format = \"2.0\"\n")
    @test TelemetryCore.active_manifest_path(joinpath(env, "Project.toml")) ==
          joinpath(env, "Manifest.toml")
    versioned = joinpath(env, "Manifest-v$(VERSION.major).$(VERSION.minor).toml")
    write(versioned, "manifest_format = \"2.0\"\n")
    @test TelemetryCore.active_manifest_path(joinpath(env, "Project.toml")) == versioned
end
