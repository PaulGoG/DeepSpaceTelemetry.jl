# Static QA: Aqua, ExplicitImports, JET over the package's own modules.

@testset "Static QA (Aqua)" begin
    # Scripts and benchmarks carry their own environments (scripts/Project.toml,
    # bench/Project.toml), so the package dependency graph is exactly what
    # src/ loads and the stale-deps check runs unexempted.
    #
    # The persistent-tasks check precompiles a generated wrapper package; under
    # the coverage flags of the CI runners that process exits without a status
    # file, so the check runs everywhere except CI. The property holds by
    # construction: `__init__` only assigns DATA_ROOT and starts no task.
    Aqua.test_all(DeepSpaceTelemetry; persistent_tasks = get(ENV, "CI", "") != "true")
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
        target_modules = (
            DeepSpaceTelemetry,
            TelemetryCore,
            ChannelEffects,
            VirtualInstrument,
            PlotTheme,
            Emitter,
            Receiver,
            Masks,
            MissionFigures,
            Metrology,
            Export,
            Publication,
            Supervisor,
        ),
    )
end
