# Static QA: Aqua, ExplicitImports, JET over both packages.

@testset "Static QA (Aqua)" begin
    # Scripts and benchmarks carry their own environments (scripts/Project.toml,
    # bench/Project.toml), so the package dependency graph is exactly what
    # src/ loads and the stale-deps check runs unexempted.
    #
    # The persistent-tasks check precompiles a generated wrapper package, whose
    # process exits without a status file under the coverage flags, so the
    # coverage leg skips it. `__init__` assigns PROJECT_ROOT and DATA_ROOT and
    # starts no task.
    persistent = !(get(ENV, "CI", "") == "true" && Base.JLOptions().code_coverage != 0)
    Aqua.test_all(DeepSpaceTelemetry; persistent_tasks = persistent)
    Aqua.test_all(DeepSpaceTelemetryReader; persistent_tasks = persistent)
end

@testset "Static QA (ExplicitImports)" begin
    for pkg in (DeepSpaceTelemetry, DeepSpaceTelemetryReader)
        @test ExplicitImports.check_no_stale_explicit_imports(pkg) === nothing
        @test ExplicitImports.check_no_implicit_imports(pkg) === nothing
        @test ExplicitImports.check_all_explicit_imports_via_owners(pkg) === nothing
        @test ExplicitImports.check_all_qualified_accesses_via_owners(pkg) === nothing
    end
end

@testset "Static QA (JET)" begin
    # JET follows the compiler, so the analysis runs on the current stable
    # release (the CI legs "1"); the compat floor and the prerelease skip it.
    # Each package is analysed from its own files: the main package never
    # calls RunAdapter, which an analysis of the main package alone misses.
    if JET.JET_AVAILABLE && VERSION >= v"1.13" && isempty(VERSION.prerelease)
        modules(pkg) =
            Tuple(m for m in (getfield(pkg, n) for n in names(pkg)) if m isa Module)
        for pkg in (DeepSpaceTelemetry, DeepSpaceTelemetryReader)
            JET.test_package(pkg; target_modules = modules(pkg))
        end
    else
        @test_skip false
    end
end
