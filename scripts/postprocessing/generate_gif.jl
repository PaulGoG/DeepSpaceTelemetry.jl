include(joinpath(@__DIR__, "..", "activate.jl"))
using DeepSpaceTelemetry
using CairoMakie, CSV, DataFrames, Dates

"""
    GifProfile

Rendering budget of the animation: canvas size in Makie units, the raster
scale applied to it, the frame ceiling, and the playback rate. `:archive`
renders the full-resolution artifact; `:web` renders a figure sized for a
README or a manual page, which keeps the file inside a few megabytes
without a post-processing pass.
"""
const GIF_PROFILES = Dict(
    :archive =>
        (canvas = (1400, 780), px_per_unit = 2, max_frames = 800, framerate = 12),
    :web => (canvas = (900, 500), px_per_unit = 1, max_frames = 240, framerate = 12),
)

"""
    link_state(bandwidth_pct, floor_pct, disruption_active) -> Tuple{String,Any}

Label and color of the link state of one metrics row. `floor_pct` is the
capacity below which the receiver attempts no transfer
(`telemetry.min_link_factor`, in percent like `bandwidth_pct`): a disruption
at or below it is a blackout, a disruption above it a degraded link, and
without a disruption the link is either inside a contact pass or in the
blind spot between two.
"""
function link_state(bandwidth_pct::Real, floor_pct::Real, disruption_active::Bool)
    transmittable = bandwidth_pct > floor_pct
    disruption_active && return (
        transmittable ? "Degraded link" : "Blackout",
        DeepSpaceTelemetry.PlotTheme.COLOR_LOST,
    )
    transmittable && return ("Contact pass", DeepSpaceTelemetry.PlotTheme.COLOR_BANDWIDTH)
    return ("Blind spot", DeepSpaceTelemetry.PlotTheme.COLOR_GUIDE)
end

function generate_telemetry_gif(run_id::String; profile::Symbol = :archive)
    haskey(GIF_PROFILES, profile) ||
        throw(ArgumentError("Unknown rendering profile :$profile."))
    budget = GIF_PROFILES[profile]
    run_dir = DeepSpaceTelemetry.TelemetryCore.run_directory(run_id)
    log_path = joinpath(run_dir, "mission_profile.csv")

    if !isfile(log_path)
        @error "mission_profile.csv not found" run_id
        exit(1)
    end

    df = DeepSpaceTelemetry.TelemetryCore.normalize_profile!(CSV.read(log_path, DataFrame))
    if isempty(df)
        @error "mission_profile.csv is empty" run_id
        exit(1)
    end

    println("Generating the batch-routing animation for run $run_id ($profile profile)...")
    println("Rendering time scales with the mission length.")

    # Shared state-machine replay: the exact event-log reconstruction (a run
    # without events_tx.csv / events_rx.csv is rejected).
    row_states = DeepSpaceTelemetry.Masks.batch_states(run_dir, df)
    run_cfg = DeepSpaceTelemetry.TelemetryCore.load_run_config(run_dir)
    floor_pct =
        100 * DeepSpaceTelemetry.TelemetryCore.telemetry_settings(run_cfg).min_link_factor
    show_lost = !isempty(row_states) && !isempty(last(row_states).lost)
    # Legacy profiles predate the loss and disruption columns.
    has_loss_col = hasproperty(df, :Lost_Count)
    has_disruption_col = hasproperty(df, :Disruption_Active)

    # Frame budget: `ceil` so the ceiling actually binds — with `floor`, any
    # row count between one and two times `max_frames` decimated by one and
    # rendered the profile in full.
    step_size = max(1, ceil(Int, nrow(df) / budget.max_frames))
    canvas = budget.canvas
    # One style, the standard layout scaled to the width of the animation
    # canvas, drives the axis theme, the legend typography, and
    # the marker sizes, so they agree within every frame. Batches on the
    # link are drawn slightly larger.
    style = DeepSpaceTelemetry.PlotTheme.PlotStyle(
        canvas[1] / DeepSpaceTelemetry.PlotTheme.FIGURE_WIDTH,
    )
    marker_size = round(Int, style.markersize)
    marker_size_link = round(Int, 1.25 * style.markersize)
    # The row carries the stage (satellite, link, ground), so color is free
    # to carry the routing family, in the Okabe–Ito hues the static figures
    # already use for it; the marker shape repeats the distinction so the
    # animation survives grayscale. Encoding the stage in the color instead
    # would duplicate the axis and leave the family — the quantity a reader
    # cannot otherwise recover — to a shape that merges once a row holds
    # hundreds of batches.
    color_live = DeepSpaceTelemetry.PlotTheme.COLOR_LIVE
    color_archive = DeepSpaceTelemetry.PlotTheme.COLOR_ARCHIVE
    color_lost = DeepSpaceTelemetry.PlotTheme.COLOR_LOST

    gif_path = joinpath(
        run_dir,
        "plots",
        profile === :web ? "telemetry_animation_web.gif" : "telemetry_animation.gif",
    )
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
            elems = Any[
                MarkerElement(
                    marker = :circle,
                    color = color_live,
                    markersize = style.markersize,
                ),
                MarkerElement(
                    marker = :diamond,
                    color = color_archive,
                    markersize = style.markersize,
                ),
            ]
            labels = ["Live (FIFO)", "Archive (LIFO)"]
            if show_lost
                push!(
                    elems,
                    MarkerElement(
                        marker = :xcross,
                        color = color_lost,
                        markersize = style.markersize,
                    ),
                )
                push!(labels, "Retry-exhausted")
            end
            Legend(
                fig[0, 1],
                elems,
                labels;
                orientation = :horizontal,
                framevisible = false,
                backgroundcolor = :transparent,
                labelsize = style.fontsize,
                colgap = round(Int, 18 * style.scale),
            )
        end

    CairoMakie.with_theme(DeepSpaceTelemetry.PlotTheme.telemetry_theme(style)) do
        # Outer margin scaled with the canvas, as the theme's 10 units are
        # set for the design width.
        fig = Figure(size = canvas, figure_padding = round(Int, 10 * style.scale))

        frame_iterator = 1:step_size:nrow(df)

        record(
            fig,
            gif_path,
            frame_iterator;
            framerate = budget.framerate,
            px_per_unit = budget.px_per_unit,
        ) do i
            empty!(fig)
            add_gif_legend!(fig)

            state = row_states[i]
            row = df[i, :]

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

            # Mission clock and buffer state in the empty band between the
            # ground and link rows: frames are profile rows, whose cadence
            # is change-driven, so without the clock the animation carries
            # no mission time at all.
            state_label, state_color = link_state(
                row.Bandwidth_Pct,
                floor_pct,
                has_disruption_col ? Bool(row.Disruption_Active) : false,
            )
            text!(
                ax,
                0.012,
                0.66,
                text = "Day $(floor(Int, row.Hours_Elapsed / 24)) · $(Dates.format(row.SimTime, "HH:MM"))",
                space = :relative,
                align = (:left, :center),
                fontsize = style.fontsize_annotation,
            )
            text!(
                ax,
                0.012,
                0.56,
                text = state_label,
                space = :relative,
                align = (:left, :center),
                fontsize = style.fontsize_annotation,
                color = state_color,
            )
            counters = "Onboard $(row.Onboard_Buffer) · Ground $(row.Ground_Total)"
            show_lost && has_loss_col && (counters *= " · Lost $(row.Lost_Count)")
            text!(
                ax,
                0.988,
                0.66,
                text = counters,
                space = :relative,
                align = (:right, :center),
                fontsize = style.fontsize_annotation,
            )

            # Live points (circles)
            if !isempty(x_onb_l)
                scatter!(
                    ax,
                    x_onb_l,
                    fill(1, length(x_onb_l)),
                    color = color_live,
                    marker = :circle,
                    markersize = marker_size,
                )
            end
            if !isempty(x_lnk_l)
                scatter!(
                    ax,
                    x_lnk_l,
                    fill(2, length(x_lnk_l)),
                    color = color_live,
                    marker = :circle,
                    markersize = marker_size_link,
                )
            end
            if !isempty(x_gnd_l)
                scatter!(
                    ax,
                    x_gnd_l,
                    fill(3, length(x_gnd_l)),
                    color = color_live,
                    marker = :circle,
                    markersize = marker_size,
                )
            end

            # Archive points (diamonds)
            if !isempty(x_onb_a)
                scatter!(
                    ax,
                    x_onb_a,
                    fill(1, length(x_onb_a)),
                    color = color_archive,
                    marker = :diamond,
                    markersize = marker_size,
                )
            end
            if !isempty(x_lnk_a)
                scatter!(
                    ax,
                    x_lnk_a,
                    fill(2, length(x_lnk_a)),
                    color = color_archive,
                    marker = :diamond,
                    markersize = marker_size_link,
                )
            end
            if !isempty(x_gnd_a)
                scatter!(
                    ax,
                    x_gnd_a,
                    fill(3, length(x_gnd_a)),
                    color = color_archive,
                    marker = :diamond,
                    markersize = marker_size,
                )
            end

            # Lost points (crosses, terminal state)
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
    println("Frames: $(length(1:step_size:nrow(df))) of $(nrow(df)) profile rows.")
    return gif_path
end

# Argument parsing: `--web` selects the README/manual rendering profile, any
# other argument is the run ID (default: the most recent run).
profile = "--web" in ARGS ? :web : :archive
positional = filter(a -> !startswith(a, "--"), ARGS)
if !isempty(positional)
    generate_telemetry_gif(first(positional); profile = profile)
else
    latest_run = DeepSpaceTelemetry.TelemetryCore.latest_run_id()
    if latest_run === nothing
        println("No runs found under $(DeepSpaceTelemetry.TelemetryCore.runs_root()).")
    else
        generate_telemetry_gif(latest_run; profile = profile)
    end
end
