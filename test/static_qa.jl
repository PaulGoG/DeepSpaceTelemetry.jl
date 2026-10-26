# Static QA: Aqua, ExplicitImports, JET over the package's own modules.

@testset "Static QA (Aqua)" begin
    # Scripts and benchmarks carry their own environments (scripts/Project.toml,
    # bench/Project.toml), so the package dependency graph is exactly what
    # src/ loads and the stale-deps check runs unexempted.
    #
    # The persistent-tasks check precompiles a generated wrapper package; under
    # the coverage flags of the CI coverage leg that process exits without a
    # status file, so the check is skipped on that leg only. The property holds
    # by construction: `__init__` only assigns DATA_ROOT and starts no task.
    persistent = !(get(ENV, "CI", "") == "true" && Base.JLOptions().code_coverage != 0)
    Aqua.test_all(DeepSpaceTelemetry; persistent_tasks = persistent)
    Aqua.test_all(DeepSpaceTelemetryReader; persistent_tasks = persistent)
end

@testset "Static QA (ExplicitImports)" begin
    for pkg in (DeepSpaceTelemetry, DeepSpaceTelemetryReader)
        @test ExplicitImports.check_no_stale_explicit_imports(pkg) === nothing
        @test ExplicitImports.check_no_implicit_imports(pkg) === nothing
    end
end

@testset "Static QA (JET)" begin
    # Reports are restricted to this package's own modules; upstream
    # dependencies are analyzed but not reported against. On a Julia version
    # JET does not support yet (the prerelease leg) JET loads empty stubs that
    # error on use; the analysis is then skipped and reported as broken rather
    # than failing the leg for a reason outside this package.
    try
        JET.test_package(
            DeepSpaceTelemetry;
            target_modules = Tuple(
                m for
                m in (getfield(DeepSpaceTelemetry, n) for n in names(DeepSpaceTelemetry)) if
                m isa Module
            ),
        )
    catch e
        e isa ErrorException &&
        occursin("Full JET functionality is not available", e.msg) || rethrow()
        @warn "[QA] JET analysis skipped on this Julia version." version = VERSION
        @test_skip false
    end
end
