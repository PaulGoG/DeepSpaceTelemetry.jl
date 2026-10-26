# A run made from an installed copy, end to end, as a downstream consumer
# makes it: the package committed to a throwaway repository, pinned by URL
# and full commit hash through [sources] in a fresh environment, installed by
# Pkg into a temporary depot (no .git in the installed tree), and run for a
# short tick mission in a subprocess. Opt-in, through
# DEEPSPACETELEMETRY_TEST_INSTALLED=true: the copy precompiles from scratch,
# which takes several minutes.

@testset "Run from an installed copy" begin
    work = mktempdir()
    project = TOML.parsefile(joinpath(TelemetryCore.PROJECT_ROOT[], "Project.toml"))

    repo = joinpath(work, "repo")
    mkpath(repo)
    for item in ("Project.toml", "src")
        cp(joinpath(TelemetryCore.PROJECT_ROOT[], item), joinpath(repo, item))
    end
    run(`git -C $repo init -q`)
    run(`$FIXTURE_GIT -C $repo add -A`)
    run(`$FIXTURE_GIT -C $repo commit -q -m fixture`)
    commit = readchomp(`git -C $repo rev-parse HEAD`)
    tree = readchomp(`git -C $repo rev-parse 'HEAD^{tree}'`)

    # The environment of the consumer, seeded with the active manifest so the
    # dependencies resolve to the versions already installed.
    env = joinpath(work, "env")
    mkpath(env)
    open(joinpath(env, "Project.toml"), "w") do io
        TOML.print(
            io,
            Dict{String,Any}(
                "deps" => Dict{String,Any}("DeepSpaceTelemetry" => project["uuid"]),
                "sources" => Dict{String,Any}(
                    "DeepSpaceTelemetry" =>
                        Dict{String,Any}("url" => repo, "rev" => commit),
                ),
            ),
        )
    end
    seed = TOML.parsefile(TelemetryCore.active_manifest_path())
    delete!(seed["deps"], "DeepSpaceTelemetry")
    open(io -> TOML.print(io, seed), joinpath(env, "Manifest.toml"), "w")

    scenario = joinpath(TelemetryCore.PROJECT_ROOT[], "scenarios", "deterministic_1d.toml")
    data_root = joinpath(work, "data")
    script = joinpath(work, "consumer.jl")
    write(
        script,
        """
        import Pkg
        Pkg.resolve(; io = devnull)
        using DeepSpaceTelemetry: TelemetryCore, Supervisor
        using Logging: NullLogger, with_logger
        TelemetryCore.DATA_ROOT[] = $(repr(data_root))
        cfg = TelemetryCore.tick_configuration(TelemetryCore.load_config($(repr(scenario))))
        cfg["simulation"]["mission_days"] = 0.05
        for key in ("session_figures", "state_raster", "alert_latency")
            cfg["post_processing"][key] = false
        end
        run_dir = with_logger(NullLogger()) do
            Supervisor.run_mission(cfg; run_id = "INSTALLED_COPY", orig_stdout = devnull)
        end
        println(pathof(TelemetryCore))
        println(run_dir)
        """,
    )
    depot = joinpath(work, "depot")
    separator = Sys.iswindows() ? ";" : ":"
    log = joinpath(work, "consumer.log")
    command = addenv(
        `$(Base.julia_cmd()) --startup-file=no --project=$env $script`,
        "JULIA_DEPOT_PATH" => join([depot; DEPOT_PATH], separator),
        "JULIA_LOAD_PATH" => join(["@", "@stdlib"], separator),
        "JULIA_PKG_PRECOMPILE_AUTO" => "0",
    )
    output = try
        read(pipeline(command; stderr = log), String)
    catch e
        e isa ProcessFailedException || rethrow()
        print(read(log, String))
        rethrow()
    end
    loaded, run_dir = split(chomp(output), '\n')[(end-1):end]
    # Loaded from the depot, not from this checkout.
    @test startswith(loaded, joinpath(depot, "packages", "DeepSpaceTelemetry"))
    @test !isdir(joinpath(dirname(dirname(loaded)), ".git"))
    manifest = TOML.parsefile(joinpath(env, "Manifest.toml"))
    entry = only(manifest["deps"]["DeepSpaceTelemetry"])
    @test entry["git-tree-sha1"] == tree && entry["repo-rev"] == commit

    descriptor = TOML.parsefile(joinpath(run_dir, "descriptor.toml"))
    @test descriptor["identity_source"] == "manifest"
    @test descriptor["git_commit"] == commit
    @test descriptor["git_tree_sha1"] == tree
    @test descriptor["git_dirty"] == false
    @test descriptor["repo_url"] == entry["repo-url"] && descriptor["repo_rev"] == commit
    @test descriptor["package_version"] == project["version"]
    platform =
        TOML.parsefile(joinpath(run_dir, "config_snapshot.toml"))["provenance"]["platform"]
    @test all(
        platform[key] == descriptor[key] for key in (
            "identity_source",
            "git_commit",
            "git_tree_sha1",
            "git_dirty",
            "repo_url",
            "repo_rev",
        )
    )
end
