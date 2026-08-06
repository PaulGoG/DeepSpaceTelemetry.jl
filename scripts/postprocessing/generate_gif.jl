using Pkg; Pkg.activate(joinpath(@__DIR__, "..", ".."), io=devnull); Pkg.instantiate(io=devnull)
include("../../src/DeepSpaceTelemetry.jl")
using .DeepSpaceTelemetry
using CairoMakie, CSV, DataFrames, Dates

function create_telemetry_gif(run_id::String)
    run_dir = joinpath(DeepSpaceTelemetry.TelemetryCore.PROJECT_ROOT, "data", "runs", run_id)
    log_path = joinpath(run_dir, "mission_profile.csv")
    
    if !isfile(log_path)
        println("Error: mission_profile.csv not found for Run $run_id")
        return
    end
    
    df = CSV.read(log_path, DataFrame)
    if isempty(df)
        println("Error: mission_profile.csv is empty.")
        return
    end
    
    println("Generating high-resolution GIF animation for Run $run_id...")
    println("Rendering time scales with the mission length.")
    
    cfg = DeepSpaceTelemetry.TelemetryCore.load_run_config(run_dir)
    tel = get(cfg, "telemetry", Dict{String, Any}())
    session_start_time = Time(get(tel, "session_start", "08:00:00"))
    session_dur = Second(round(Int, Float64(get(tel, "session_duration_hours", 8.0)) * 3600))
    bw_profile = String(get(tel, "bandwidth_profile", "sine"))
    vis_model = DeepSpaceTelemetry.TelemetryCore.VisibilityModel(session_start_time, session_dur, bw_profile)

    # Shared state-machine replay (exact event-log reconstruction when the run
    # carries events_tx.csv / events_rx.csv; heuristic fallback otherwise)
    row_states = DeepSpaceTelemetry.Receiver.batch_states(run_dir, df, vis_model)
    last_total = isempty(row_states) ? 0 : sum(length, last(row_states))
    show_lost = !isempty(row_states) && !isempty(last(row_states).lost)

    n_frames = min(nrow(df), 800)
    step_size = max(1, floor(Int, nrow(df) / n_frames))
    msize = 10

    gif_path = joinpath(run_dir, "plots", "telemetry_animation.gif")
    mkpath(dirname(gif_path)) # legacy/interrupted runs may lack plots/

    # Camera state for the sliding x-window: keep a trailing buffer of
    # already-grounded batches visible behind the drain edge, a lookahead
    # margin past the newest batch, glide both edges smoothly, and freeze
    # (instead of snapping to the mission end) whenever the satellite/link
    # are momentarily empty.
    trail_buffer = 15
    lead_buffer = 20
    glide = 0.15
    view_min = 0.0
    view_max = 50.0

    # Frameless legend strip above the tracker, mirroring the static plots.
    # Grouped by routing class; the Lost group appears only in lossy runs.
    add_gif_legend! = fig -> begin
        groups = [[MarkerElement(marker=:circle, color=c, markersize=14) for c in (:red, :yellow, :cyan)],
                  [MarkerElement(marker=:diamond, color=c, markersize=14) for c in (:magenta, :blue, :green)]]
        glabels = [["Satellite", "In-Transit", "Ground"],
                   ["Satellite", "In-Transit", "Ground"]]
        gtitles = ["Live (FIFO):", "Archive (LIFO):"]
        if show_lost
            push!(groups, [MarkerElement(marker=:xcross, color=DeepSpaceTelemetry.PlotTheme.COLOR_LOST, markersize=14)])
            push!(glabels, ["Retry-exhausted"])
            push!(gtitles, "Lost:")
        end
        Legend(fig[0, 1], groups, glabels, gtitles;
               orientation=:horizontal, titleposition=:left, framevisible=false,
               backgroundcolor=:transparent, labelsize=18, titlesize=20,
               titlegap=8, colgap=16, groupgap=36, patchsize=(22, 18))
    end

    DeepSpaceTelemetry.PlotTheme.with_theme(DeepSpaceTelemetry.PlotTheme.telemetry_theme()) do
        fig = Figure(size=(1400, 780), figure_padding=20)

        frame_iterator = 1:step_size:nrow(df)

        record(fig, gif_path, frame_iterator; framerate=12) do i
            empty!(fig)
            add_gif_legend!(fig)

            state = row_states[i]

            x_onb_l, x_onb_a = state.onb_live, state.onb_arch
            x_lnk_l, x_lnk_a = state.lnk_live, state.lnk_arch
            x_gnd_l, x_gnd_a = state.gnd_live, state.gnd_arch
            x_lost = state.lost

            active_x = vcat(x_onb_l, x_onb_a, x_lnk_l, x_lnk_a)
            all_x = vcat(active_x, x_gnd_l, x_gnd_a, x_lost)

            target_min = isempty(active_x) ? view_min : Float64(max(0, minimum(active_x) - trail_buffer))
            target_max = isempty(all_x) ? view_max : Float64(maximum(all_x) + lead_buffer)
            view_min += glide * (target_min - view_min)
            view_max += glide * (target_max - view_max)

            xlim_min = view_min
            xlim_max = max(view_max, view_min + 50)

            ytick_vals = show_lost ? [0, 1, 2, 3] : [1, 2, 3]
            ytick_labels = show_lost ? ["Lost", "Satellite", "In-Transit", "Ground Archive"] :
                                       ["Satellite", "In-Transit", "Ground Archive"]
            ax = Axis(fig[1,1], xlabel="Batch ID", ylabel="",
                      yticks=(ytick_vals, ytick_labels))
            xlims!(ax, xlim_min, xlim_max)
            ylims!(ax, show_lost ? -0.5 : 0.5, 3.5)

            # Live points (Circles)
            if !isempty(x_onb_l) scatter!(ax, x_onb_l, fill(1, length(x_onb_l)), color=:red, marker=:circle, markersize=msize) end
            if !isempty(x_lnk_l) scatter!(ax, x_lnk_l, fill(2, length(x_lnk_l)), color=:yellow, marker=:circle, markersize=msize+2) end
            if !isempty(x_gnd_l) scatter!(ax, x_gnd_l, fill(3, length(x_gnd_l)), color=:cyan, marker=:circle, markersize=msize) end

            # Arch points (Diamonds)
            if !isempty(x_onb_a) scatter!(ax, x_onb_a, fill(1, length(x_onb_a)), color=:magenta, marker=:diamond, markersize=msize) end
            if !isempty(x_lnk_a) scatter!(ax, x_lnk_a, fill(2, length(x_lnk_a)), color=:blue, marker=:diamond, markersize=msize+2) end
            if !isempty(x_gnd_a) scatter!(ax, x_gnd_a, fill(3, length(x_gnd_a)), color=:green, marker=:diamond, markersize=msize) end

            # Lost points (X crosses, terminal state)
            if !isempty(x_lost) scatter!(ax, x_lost, fill(0, length(x_lost)), color=DeepSpaceTelemetry.PlotTheme.COLOR_LOST, marker=:xcross, markersize=msize+2) end
        end
    end
    
    println("GIF animation saved to: $gif_path")
end

if length(ARGS) > 0
    create_telemetry_gif(ARGS[1])
else
    runs_dir = joinpath(DeepSpaceTelemetry.TelemetryCore.PROJECT_ROOT, "data", "runs")
    if isdir(runs_dir)
        runs = filter(x -> startswith(x, "RUN_"), readdir(runs_dir))
        if !isempty(runs)
            latest_run = last(sort(runs, by=x -> mtime(joinpath(runs_dir, x))))
            create_telemetry_gif(latest_run)
        else
            println("No runs found.")
        end
    else
        println("Runs directory not found.")
    end
end
