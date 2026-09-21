include(joinpath(@__DIR__, "..", "activate.jl"))
using DeepSpaceTelemetry

"""
    cleanup_runs(; assume_yes::Bool = false)

Delete all previous simulation run directories from the runs root
(`TelemetryCore.runs_root()`, i.e. `<DATA_ROOT>/runs`). Lists the deletion
candidates and asks for interactive confirmation first; pass
`assume_yes = true` (CLI flag `--yes`) to skip the prompt in non-interactive
contexts.
"""
function cleanup_runs(; assume_yes::Bool = false)
    run_path = DeepSpaceTelemetry.TelemetryCore.runs_root()
    if !isdir(run_path)
        println("Run directory not found. Nothing to clean.")
        return
    end
    runs = filter(!=(".gitkeep"), readdir(run_path))
    if isempty(runs)
        println("No previous runs found to clean.")
        return
    end
    println("Deletion candidates in $run_path:")
    foreach(r -> println("  - $r"), runs)
    if !assume_yes
        print("Delete these $(length(runs)) run directories? [y/N] ")
        reply = strip(lowercase(readline()))
        if reply != "y" && reply != "yes"
            println("Aborted; no data deleted.")
            return
        end
    end
    for run in runs
        rm(joinpath(run_path, run), recursive = true, force = true)
    end
    println("Cleanup complete: $(length(runs)) run directories removed.")
end

cleanup_runs(assume_yes = any(a -> a == "--yes" || a == "-y", ARGS))
