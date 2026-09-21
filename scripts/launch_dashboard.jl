include(joinpath(@__DIR__, "activate.jl"))
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
# directory and the log follower waits for absent log files to appear.
run_id = DeepSpaceTelemetry.TelemetryCore.generate_run_id()
run_dir = DeepSpaceTelemetry.TelemetryCore.run_directory(run_id)

println("Launching dashboard terminals for run: $run_id...")

# Commands to run in the new windows: absolute paths, no working-directory
# assumption, and a pure-Julia log follower (scripts/follow_log.jl) in place
# of `tail -F`.
julia_scripts = "julia"
live_viewer_cmd = "$julia_scripts \"$(joinpath(@__DIR__, "live_viewer.jl"))\" $run_id"
follow_log = joinpath(@__DIR__, "follow_log.jl")
tail_rx_cmd = "$julia_scripts \"$follow_log\" \"$(joinpath(run_dir, "receiver.log"))\""
tail_tx_cmd = "$julia_scripts \"$follow_log\" \"$(joinpath(run_dir, "emitter.log"))\""

# Windows to open, from the validated [dashboard] settings.
dashboard = DeepSpaceTelemetry.TelemetryCore.dashboard_settings(cfg)
dashboard.open_live_viewer && launch_terminal("Telemetry Live Viewer", live_viewer_cmd)
dashboard.open_receiver_log && launch_terminal("Receiver Log", tail_rx_cmd)
dashboard.open_emitter_log && launch_terminal("Emitter Log", tail_tx_cmd)

println("Dashboard launched: live viewer and log-tail terminals spawned.")
println(
    "Starting main simulation (span: $(DeepSpaceTelemetry.TelemetryCore.mission_wall_seconds(cfg)) wall-clock s)...",
)
println("="^55)

# Give terminals a second to open before starting the data generation
sleep(1.5)

# Pass the run_id (and any config path) to the simulation script
empty!(ARGS)
push!(ARGS, run_id)
isempty(config_arg) || push!(ARGS, config_arg)
include(joinpath(@__DIR__, "run_full_sim.jl"))
