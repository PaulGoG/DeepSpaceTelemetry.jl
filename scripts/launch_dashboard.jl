using Pkg
Pkg.activate(@__DIR__, io = devnull)
Pkg.instantiate(io = devnull)

using DeepSpaceTelemetry

function launch_terminal(title::String, cmd::String)
    if Sys.islinux()
        if !isnothing(Sys.which("gnome-terminal"))
            run(
                Cmd([
                    "gnome-terminal",
                    "--title",
                    title,
                    "--",
                    "bash",
                    "-c",
                    "$cmd; exec bash",
                ]),
                wait = false,
            )
        elseif !isnothing(Sys.which("konsole"))
            run(
                Cmd(["konsole", "--title", title, "-e", "bash", "-c", "$cmd; exec bash"]),
                wait = false,
            )
        elseif !isnothing(Sys.which("xterm"))
            run(
                Cmd(["xterm", "-title", title, "-e", "bash", "-c", "$cmd; exec bash"]),
                wait = false,
            )
        else
            @warn "Could not find supported GUI terminal. Run manually in a new window:\n$cmd"
        end
    elseif Sys.isapple()
        apple_cmd = "osascript -e 'tell application \"Terminal\" to do script \"cd $(pwd()) && $cmd\"'"
        run(Cmd(["sh", "-c", apple_cmd]), wait = false)
    elseif Sys.iswindows()
        run(Cmd(["cmd", "/c", "start", title, "cmd", "/k", cmd]), wait = false)
    else
        @warn "Unsupported OS for automated terminal launching. Run manually:\n$cmd"
    end
end

println("Starting the DeepSpaceTelemetry dashboard.")

# Change to project root so paths are correct
cd(joinpath(@__DIR__, ".."))

# Load Config — any CLI argument ending in ".toml" selects an alternative
# config file (forwarded to run_full_sim.jl below).
config_idx = findfirst(a -> endswith(a, ".toml"), ARGS)
config_arg = config_idx === nothing ? "" : ARGS[config_idx]
cfg = DeepSpaceTelemetry.TelemetryCore.load_config(config_arg)

# Fail fast on an invalid configuration before any terminal is spawned.
DeepSpaceTelemetry.TelemetryCore.validate_config(cfg)

# Generate a run ID. The run directory itself is created exactly once, by
# run_full_sim.jl below — pre-creating it here would trip the run-ID reuse
# guard in setup_run_dir. The viewer tolerates the not-yet-existing
# directory and `tail -F` retries absent log files until they appear.
run_id = DeepSpaceTelemetry.TelemetryCore.generate_run_id()
run_dir = DeepSpaceTelemetry.TelemetryCore.run_directory(run_id)

println("Launching dashboard terminals for run: $run_id...")

# Commands to run in the new windows
live_viewer_cmd = "julia --project=. scripts/live_viewer.jl $run_id"
tail_rx_cmd = "tail -F $(joinpath("data", "runs", run_id, "receiver.log"))"
tail_tx_cmd = "tail -F $(joinpath("data", "runs", run_id, "emitter.log"))"

# Choose which windows to open based on config
db_cfg = get(cfg, "dashboard", Dict())
if get(db_cfg, "open_live_viewer", true)
    launch_terminal("Telemetry Live Viewer", live_viewer_cmd)
end
if get(db_cfg, "open_receiver_log", true)
    launch_terminal("Receiver Log", tail_rx_cmd)
end
if get(db_cfg, "open_emitter_log", true)
    launch_terminal("Emitter Log", tail_tx_cmd)
end

println("Dashboard launched: live viewer and log-tail terminals spawned.")
println(
    "Starting main simulation (duration: $(cfg["simulation"]["test_duration_sec"]) s)...",
)
println("="^55)

# Give terminals a second to open before starting the data generation
sleep(1.5)

# Pass the run_id (and any config path) to the simulation script
empty!(ARGS)
push!(ARGS, run_id)
isempty(config_arg) || push!(ARGS, config_arg)
include("run_full_sim.jl")
