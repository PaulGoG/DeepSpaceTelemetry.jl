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
    Aqua.test_all(
        DeepSpaceTelemetry;
        persistent_tasks = !(
            get(ENV, "CI", "") == "true" && Base.JLOptions().code_coverage != 0
        ),
    )
end

@testset "Static QA (ExplicitImports)" begin
    @test ExplicitImports.check_no_stale_explicit_imports(DeepSpaceTelemetry) === nothing
    @test ExplicitImports.check_no_implicit_imports(DeepSpaceTelemetry) === nothing
end

@testset "Static QA (JET)" begin
    # Reports are restricted to this package's own modules; upstream
    # dependencies are analyzed but not reported against.
    JET.test_package(
        DeepSpaceTelemetry;
        target_modules = Tuple(
            m for
            m in (getfield(DeepSpaceTelemetry, n) for n in names(DeepSpaceTelemetry)) if
            m isa Module
        ),
    )
end
