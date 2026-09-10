using Pkg;
Pkg.activate(joinpath(@__DIR__, ".."), io = devnull);
Pkg.instantiate(io = devnull)
using DeepSpaceTelemetry
using CairoMakie, CSV, DataFrames, Dates

function generate_telemetry_gif(run_id::String)
    run_dir = DeepSpaceTelemetry.TelemetryCore.run_directory(run_id)
    log_path = joinpath(run_dir, "mission_profile.csv")

    if !isfile(log_path)
        "mission_profile.csv not found for run "
        return
    end

    df = DeepSpaceTelemetry.TelemetryCore.normalize_profile!(CSV.read(log_path, DataFrame))
    if isempty(df)
        "mission_profile.csv of run  is empty"
        return
    end

    println("Generating high-resolution GIF animation for Run $run_id...")
    println("Rendering time scales with the mission length.")

    # Shared state-machine replay: the exact event-log reconstruction (a run
    # without events_tx.csv / events_rx.csv is rejected).
    row_states = DeepSpaceTelemetry.Receiver.batch_states(run_dir, df)
    show_lost = !isempty(row_states) && !isempty(last(row_states).lost)

    # Frame budget: at most `max_frames` snapshots, sampled uniformly.
    max_frames = min(nrow(df), 800)
    step_size = max(1, floor(Int, nrow(df) / max_frames))
    # Marker sizes derive from the print-scale theme constant; the animation
    # canvas (1400 × 780 units) is wider than the static figures, hence the
    # scale factor. Batches on the link are drawn slightly larger.
    marker_size = round(Int, 1.25 * DeepSpaceTelemetry.PlotTheme.MARKERSIZE_DATA)
    marker_size_link = marker_size + 2
    # Okabe–Ito semantics shared with the static figures: color encodes the
    # stage (onboard buffer, link, ground), marker shape encodes the family
    # (circle = live/FIFO, diamond = archive/LIFO).
    color_onboard = DeepSpaceTelemetry.PlotTheme.COLOR_ONBOARD
    color_link = DeepSpaceTelemetry.PlotTheme.COLOR_BANDWIDTH
    color_ground_live = DeepSpaceTelemetry.PlotTheme.COLOR_LIVE
    color_ground_archive = DeepSpaceTelemetry.PlotTheme.COLOR_ARCHIVE
    color_lost = DeepSpaceTelemetry.PlotTheme.COLOR_LOST

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
    add_gif_legend! =
        fig -> begin
            groups = [
                [
                    MarkerElement(marker = :circle, color = c, markersize = 14) for
                    c in (color_onboard, color_link, color_ground_live)
                ],
                [
                    MarkerElement(marker = :diamond, color = c, markersize = 14) for
                    c in (color_onboard, color_link, color_ground_archive)
                ],
            ]
            glabels = [["Satellite", "Link", "Ground"], ["Satellite", "Link", "Ground"]]
            gtitles = ["Live (FIFO):", "Archive (LIFO):"]
            if show_lost
                push!(
                    groups,
                    [MarkerElement(marker = :xcross, color = color_lost, markersize = 14)],
                )
                push!(glabels, ["Retry-exhausted"])
                push!(gtitles, "Lost:")
            end
            Legend(
                fig[0, 1],
                groups,
                glabels,
                gtitles;
                orientation = :horizontal,
                titleposition = :left,
                framevisible = false,
                backgroundcolor = :transparent,
                labelsize = 18,
                titlesize = 20,
                titlegap = 8,
                colgap = 16,
                groupgap = 36,
                patchsize = (22, 18),
            )
        end

    CairoMakie.with_theme(DeepSpaceTelemetry.PlotTheme.telemetry_theme()) do
        fig = Figure(size = (1400, 780), figure_padding = 20)

        frame_iterator = 1:step_size:nrow(df)

        record(fig, gif_path, frame_iterator; framerate = 12) do i
            empty!(fig)
            add_gif_legend!(fig)

            state = row_states[i]

            x_onb_l, x_onb_a = state.onboard_live, state.onboard_archive
            x_lnk_l, x_lnk_a = state.link_live, state.link_archive
            x_gnd_l, x_gnd_a = state.ground_live, state.ground_archive
            x_lost = state.lost

            active_x = vcat(x_onb_l, x_onb_a, x_lnk_l, x_lnk_a)
            all_x = vcat(active_x, x_gnd_l, x_gnd_a, x_lost)

            target_min =
                isempty(active_x) ? view_min :
                Float64(max(0, minimum(active_x) - trail_buffer))
            target_max = isempty(all_x) ? view_max : Float64(maximum(all_x) + lead_buffer)
            view_min += glide * (target_min - view_min)
            view_max += glide * (target_max - view_max)

            xlim_min = view_min
            xlim_max = max(view_max, view_min + 50)

            ytick_vals = show_lost ? [0, 1, 2, 3] : [1, 2, 3]
            ytick_labels =
                show_lost ? ["Lost", "Satellite", "Link", "Ground"] :
                ["Satellite", "Link", "Ground"]
            ax = Axis(
                fig[1, 1],
                xlabel = "Batch ID",
                ylabel = "",
                yticks = (ytick_vals, ytick_labels),
            )
            xlims!(ax, xlim_min, xlim_max)
            ylims!(ax, show_lost ? -0.5 : 0.5, 3.5)

            # Live points (Circles)
            if !isempty(x_onb_l)
                scatter!(
                    ax,
                    x_onb_l,
                    fill(1, length(x_onb_l)),
                    color = color_onboard,
                    marker = :circle,
                    markersize = marker_size,
                )
            end
            if !isempty(x_lnk_l)
                scatter!(
                    ax,
                    x_lnk_l,
                    fill(2, length(x_lnk_l)),
                    color = color_link,
                    marker = :circle,
                    markersize = marker_size_link,
                )
            end
            if !isempty(x_gnd_l)
                scatter!(
                    ax,
                    x_gnd_l,
                    fill(3, length(x_gnd_l)),
                    color = color_ground_live,
                    marker = :circle,
                    markersize = marker_size,
                )
            end

            # Arch points (Diamonds)
            if !isempty(x_onb_a)
                scatter!(
                    ax,
                    x_onb_a,
                    fill(1, length(x_onb_a)),
                    color = color_onboard,
                    marker = :diamond,
                    markersize = marker_size,
                )
            end
            if !isempty(x_lnk_a)
                scatter!(
                    ax,
                    x_lnk_a,
                    fill(2, length(x_lnk_a)),
                    color = color_link,
                    marker = :diamond,
                    markersize = marker_size_link,
                )
            end
            if !isempty(x_gnd_a)
                scatter!(
                    ax,
                    x_gnd_a,
                    fill(3, length(x_gnd_a)),
                    color = color_ground_archive,
                    marker = :diamond,
                    markersize = marker_size,
                )
            end

            # Lost points (X crosses, terminal state)
            if !isempty(x_lost)
                scatter!(
                    ax,
                    x_lost,
                    fill(0, length(x_lost)),
                    color = color_lost,
                    marker = :xcross,
                    markersize = marker_size_link,
                )
            end
        end
    end

    println("GIF animation saved to: $gif_path")
end

if length(ARGS) > 0
    generate_telemetry_gif(ARGS[1])
else
    latest_run = DeepSpaceTelemetry.TelemetryCore.latest_run_id()
    if latest_run === nothing
        println("No runs found under $(DeepSpaceTelemetry.TelemetryCore.runs_root()).")
    else
        generate_telemetry_gif(latest_run)
    end
end
