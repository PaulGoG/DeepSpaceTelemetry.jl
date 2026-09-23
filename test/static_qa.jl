# Static QA: Aqua, ExplicitImports, JET over the package's own modules.

@testset "Static QA (Aqua)" begin
    # Scripts and benchmarks carry their own environments (scripts/Project.toml,
    # bench/Project.toml), so the package dependency graph is exactly what
    # src/ loads and the stale-deps check runs unexempted.
    #
    # The persistent-tasks check generates a wrapper package resolved against
    # the live registry and precompiles it under the parent's flags. On the
    # GitHub runners that recompiles the whole stack in coverage mode and the
    # wrapper process then exits without a status file or any error output
    # (2026-09-07, both matrix jobs), while the identical invocation passes
    # locally. The check therefore runs everywhere except CI; the property
    # itself holds by construction — `__init__` only assigns DATA_ROOT and no
    # task is started at load.
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
