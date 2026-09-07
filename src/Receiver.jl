"""
    Receiver

The ground-station loop and post-processing: bandwidth-paced ingestion with
stochastic loss and retransmission, the retention custodian, metrics and
`events_rx.csv` recording, and the derived products (mission/session
figures, the 2D batch-state mask timeline, batch epoch map). Re-entrant: a
restarted receiver reseeds retry and custodial state from the event log.
"""
module Receiver

using ..TelemetryCore
using ..ChannelEffects
using ..PlotTheme
using CSV: CSV
using CairoMakie:
    CairoMakie,
    Auto,
    Axis,
    Figure,
    Legend,
    LineElement,
    LinearTicks,
    MarkerElement,
    PolyElement,
    band!,
    hidespines!,
    hidexdecorations!,
    lines!,
    linkxaxes!,
    rowsize!,
    save,
    scatter!,
    stairs!,
    text!,
    translate!,
    vlines!,
    vspan!,
    with_theme,
    xlims!,
    ylims!
using DataFrames: DataFrames, DataFrame, nrow
using Dates: Dates, Date, DateTime, Day, Hour, Millisecond, Second, now
using FileWatching: FileWatching, watch_folder

"""
    generate_mission_plots(run_dir::String)

Reads the `mission_profile.csv` and generates publication-quality dual-axis plots
for the global mission state and individual session telemetry events using CairoMakie.
Outputs are saved into the `<run_dir>/plots` directory.
"""
function generate_mission_plots(run_dir::String)
    @info "[RECEIVER] Generating mission and session plots..."

    log_path = joinpath(run_dir, "mission_profile.csv")
    if !isfile(log_path)
        @warn "[POST] mission_profile.csv missing in $run_dir — the receiver produced no metrics (component never ran?); skipping this product."
        return
    end

    df = CSV.read(log_path, DataFrame)
    if isempty(df)
        return
    end

    cfg = TelemetryCore.load_run_config(run_dir)
    tel_settings = TelemetryCore.telemetry_settings(cfg)
    session_start_time = tel_settings.session_start
    session_dur = tel_settings.session_duration
    vis_model = TelemetryCore.visibility_model(cfg)

    # Disruption timeline from the run snapshot (empty for legacy/stub
    # configs). A malformed snapshot must not abort post-processing of an
    # otherwise complete run: warn and plot without disruption shading.
    disruptions = try
        haskey(get(cfg, "simulation", Dict{String,Any}()), "start_sim_time") ?
        ChannelEffects.build_disruption_timeline(
            cfg,
            DateTime(cfg["simulation"]["start_sim_time"]),
        ) : ChannelEffects.DisruptionTimeline()
    catch e
        @warn "[RECEIVER] Could not parse disruption events from the run snapshot; plotting without disruption shading." exception =
            e
        ChannelEffects.DisruptionTimeline()
    end
    link_model = ChannelEffects.LinkModel(vis_model, disruptions)

    has_loss_cols = hasproperty(df, :Lost_Count)
    any_lost = has_loss_cols && maximum(df.Lost_Count) > 0
    # The dedicated Lost strip renders whenever the loss channel was enabled —
    # an empty strip honestly reports "no losses" — and for legacy runs that
    # recorded losses without a config snapshot.
    loss_enabled = Bool(get(get(cfg, "packet_loss", Dict{String,Any}()), "enabled", false))
    show_lost_panel = (loss_enabled && has_loss_cols) || any_lost

    # Anchor the time axis at start_sim_time — NOT at the first metrics row,
    # which lands whenever the receiver first flushes (minutes to hours into
    # the mission) and would shift every gridline by that accident. With this
    # anchor, day ticks and disruption shading sit exactly on mission-day
    # boundaries. Convention: 0-based elapsed days — "Day k" = start + k·24 h —
    # matching disruption.start_day and the t₀-anchored elapsed-time axes of
    # detection/estimation pipelines.
    sim_start = try
        DateTime(get(get(cfg, "simulation", Dict{String,Any}()), "start_sim_time", ""))
    catch
        nothing # legacy/corrupt snapshot: fall back to the first metrics row
    end
    t_start_dt = something(sim_start, df.SimTime[1])
    to_h = d -> Float64((d - t_start_dt).value) / (1000 * 3600)
    df_x = to_h.(df.SimTime)

    # Disruption spans in plot coordinates: (blackout_start, blackout_end, recovery_end)
    disruption_spans = [
        (to_h(ev.start_time), to_h(ev.blackout_end), to_h(ev.recovery_end)) for
        ev in disruptions.events
    ]

    # Component-outage spans from the supervisor's lifecycle record: each
    # `down` opens a window closed by the next `restart` of the same
    # component (or mission end). Shaded distinctly from configured
    # disruption events — these are unscheduled infrastructure outages.
    outage_spans = Tuple{Float64,Float64}[]
    comp_events_path = joinpath(run_dir, "component_events.csv")
    if isfile(comp_events_path)
        ce = CSV.read(comp_events_path, DataFrame)
        open_down = Dict{String,DateTime}()
        for r in eachrow(ce)
            comp = String(r.Component)
            if r.Event == "down"
                open_down[comp] = r.SimTime
            elseif r.Event == "restart" && haskey(open_down, comp)
                push!(outage_spans, (to_h(pop!(open_down, comp)), to_h(r.SimTime)))
            end
        end
        for (_, t_down) in open_down
            push!(outage_spans, (to_h(t_down), maximum(df_x)))
        end
    end
    shade_outages! =
        (ax, x_lo, x_hi) -> begin
            for (o0, o1) in outage_spans
                o0c, o1c = max(o0, x_lo), min(o1, x_hi)
                if o0c < o1c
                    v = vspan!(ax, o0c, o1c, color = (:black, 0.10))
                    translate!(v, 0, 0, -99)
                    for x_edge in (o0, o1)
                        if x_lo <= x_edge <= x_hi
                            l = vlines!(
                                ax,
                                [x_edge],
                                color = (:gray40, 0.8),
                                linestyle = :dot,
                                linewidth = 1.5,
                            )
                            translate!(l, 0, 0, -98)
                        end
                    end
                end
            end
        end
    outage_in = (x_lo, x_hi) -> any(s -> s[1] < x_hi && s[2] > x_lo, outage_spans)

    # Shades every disruption event onto `ax`, clamped to the plotted range:
    # a uniform dark wash over the blackout, fading linearly to zero alpha
    # across the recovery ramp (mirroring the capacity ramp), with dashed
    # vlines delimiting event start and full recovery. All shading is pushed
    # far back along z so it renders behind the data identically on every
    # panel of every figure — but strictly above z = -100, where the white
    # background of a twin Axis (dual-y panels) would cover it.
    shade_disruptions! =
        (ax, x_lo, x_hi) -> begin
            for (b0, b1, r1) in disruption_spans
                b0c, b1c = max(b0, x_lo), min(b1, x_hi)
                if b0c < b1c
                    v = vspan!(ax, b0c, b1c, color = (COLOR_DISRUPTION, 0.18))
                    translate!(v, 0, 0, -99)
                end
                r0c, r1c = max(b1, x_lo), min(r1, x_hi)
                if r0c < r1c
                    edges = collect(range(r0c, r1c, length = 25))
                    for k in 1:(length(edges)-1)
                        mid = (edges[k] + edges[k+1]) / 2
                        fade = 0.18 * (1.0 - (mid - b1) / (r1 - b1))
                        v = vspan!(
                            ax,
                            edges[k],
                            edges[k+1],
                            color = (COLOR_DISRUPTION, fade),
                        )
                        translate!(v, 0, 0, -99)
                    end
                end
                for x_edge in (b0, r1)
                    if x_lo <= x_edge <= x_hi
                        l = vlines!(
                            ax,
                            [x_edge],
                            color = (:gray30, 0.8),
                            linestyle = :dash,
                            linewidth = 1.5,
                        )
                        translate!(l, 0, 0, -98)
                    end
                end
            end
        end

    # True when any blackout / recovery-ramp phase overlaps the plotted
    # x-window — legends must only advertise what their own figure actually
    # draws, and the two phases are gated independently (a pure-blackout
    # session must not list a ramp patch, and vice versa).
    blackout_in = (x_lo, x_hi) -> any(s -> s[1] < x_hi && s[2] > x_lo, disruption_spans)
    ramp_in = (x_lo, x_hi) -> any(s -> s[2] < x_hi && s[3] > x_lo, disruption_spans)

    # One frameless horizontal legend strip per figure, above the panels, with
    # composite fill+edge patches for the band+stair pairs. Entries are
    # strictly limited to what that specific figure draws: `shading` gates the
    # Blackout/Recovery patches, `lost` is :strip (summary stairs+marks),
    # :marks (session ✕ pins), or :none.
    add_figure_legend! =
        (fig; degraded, blackout, ramp, lost, outage = false) -> begin
            elems = Any[]
            labels = String[]
            if degraded
                push!(
                    elems,
                    LineElement(
                        color = (COLOR_BANDWIDTH, 0.5),
                        linewidth = 2 * PlotTheme.LINEWIDTH_DATA,
                        linestyle = :dot,
                    ),
                )
                push!(labels, "Nominal capacity")
                push!(
                    elems,
                    LineElement(
                        color = COLOR_BANDWIDTH,
                        linewidth = 2 * PlotTheme.LINEWIDTH_DATA,
                    ),
                )
                push!(labels, "Effective capacity")
            else
                push!(
                    elems,
                    LineElement(
                        color = COLOR_BANDWIDTH,
                        linewidth = 2 * PlotTheme.LINEWIDTH_DATA,
                    ),
                )
                push!(labels, "Link capacity")
            end
            push!(
                elems,
                LineElement(
                    color = COLOR_ONBOARD,
                    linewidth = 2 * PlotTheme.LINEWIDTH_DATA,
                    linestyle = :dash,
                ),
            )
            push!(labels, "Onboard buffer")
            push!(
                elems,
                PolyElement(
                    color = (COLOR_LIVE, 0.4),
                    strokecolor = COLOR_LIVE,
                    strokewidth = 3,
                ),
            )
            push!(labels, "Total received (live + archive)")
            push!(
                elems,
                PolyElement(
                    color = (COLOR_ARCHIVE, 0.4),
                    strokecolor = COLOR_ARCHIVE,
                    strokewidth = 3,
                ),
            )
            push!(labels, "Archive backfill (LIFO)")
            if lost === :strip
                push!(
                    elems,
                    [
                        LineElement(
                            color = COLOR_LOST,
                            linewidth = 2 * PlotTheme.LINEWIDTH_DATA,
                        ),
                        MarkerElement(
                            marker = :xcross,
                            color = COLOR_LOST,
                            markersize = PlotTheme.MARKERSIZE_DATA,
                        ),
                    ],
                )
                push!(labels, "Lost")
            elseif lost === :marks
                push!(
                    elems,
                    MarkerElement(
                        marker = :xcross,
                        color = COLOR_LOST,
                        markersize = PlotTheme.MARKERSIZE_DATA,
                    ),
                )
                push!(labels, "Lost")
            end
            if blackout
                push!(elems, PolyElement(color = (COLOR_DISRUPTION, 0.18)))
                push!(labels, "Blackout")
            end
            if ramp
                push!(elems, PolyElement(color = (COLOR_DISRUPTION, 0.08)))
                push!(labels, "Recovery ramp")
            end
            if outage
                push!(elems, PolyElement(color = (:black, 0.10)))
                push!(labels, "Component outage")
            end
            Legend(
                fig[0, 1],
                elems,
                labels;
                orientation = :horizontal,
                nbanks = length(elems) > 3 ? 2 : 1,
                framevisible = false,
                backgroundcolor = :transparent,
                colgap = 28,
            )
        end

    # 1. Generate Global Summary Plot
    # Floor at one hour: a single-row (or sub-hour) profile would otherwise
    # produce degenerate axis limits and crash the renderer.
    max_x_h = max(df_x[end], 1.0)
    total_days = max_x_h / 24.0

    # Dynamic tick step based on mission duration
    if total_days <= 10
        tick_step_h = 24.0
    elseif total_days <= 45
        tick_step_h = 24.0 * 2 # Every other day
    elseif total_days <= 200
        tick_step_h = 24.0 * 30 # Monthly
    else
        tick_step_h = 24.0 * 60 # Bi-monthly
    end

    tick_vals_h = collect(0.0:tick_step_h:max_x_h)
    tick_labels = ["Day $(Int(floor(v/24)))" for v in tick_vals_h]

    with_theme(telemetry_theme()) do
        fig_global = Figure(
            size = (
                PlotTheme.FIG_SIZE_SUMMARY[1],
                show_lost_panel ? PlotTheme.FIG_SIZE_SUMMARY[2] + 90 :
                PlotTheme.FIG_SIZE_SUMMARY[2],
            ),
            figure_padding = 10,
        )

        # Dual Y-axis for global plot 1
        ax1 = Axis(
            fig_global[1, 1],
            xlabel = "",
            ylabel = "Bandwidth [%]",
            xticks = (tick_vals_h, tick_labels),
        )
        xlims!(ax1, 0, max_x_h)
        ylims!(ax1, 0, 105)

        ax1_twin = Axis(
            fig_global[1, 1],
            yaxisposition = :right,
            ylabel = "Buffered data batches",
            yticklabelcolor = COLOR_ONBOARD,
        )
        hidespines!(ax1_twin)
        hidexdecorations!(ax1_twin)
        xlims!(ax1_twin, 0, max_x_h)

        max_onb = maximum(df.Onboard_Buffer)
        ylims!(ax1_twin, 0, max(10.0, 1.3 * max_onb))

        shade_disruptions!(ax1, 0.0, max_x_h)
        shade_outages!(ax1, 0.0, max_x_h)

        # Nominal (visibility-only) capacity behind the effective curve when a
        # disruption degraded the link somewhere in the run.
        show_nominal =
            hasproperty(df, :Nominal_Bandwidth_Pct) &&
            maximum(abs.(df.Nominal_Bandwidth_Pct .- df.Bandwidth_Pct)) > 0.1
        if show_nominal
            lines!(
                ax1,
                df_x,
                Float64.(df.Nominal_Bandwidth_Pct),
                color = (COLOR_BANDWIDTH, 0.35),
                linestyle = :dot,
            )
        end
        lines!(ax1, df_x, Float64.(df.Bandwidth_Pct), color = COLOR_BANDWIDTH)
        lines!(
            ax1_twin,
            df_x,
            Float64.(df.Onboard_Buffer),
            color = COLOR_ONBOARD,
            linestyle = :dash,
        )

        # Global plot 2
        ax2 = Axis(
            fig_global[2, 1],
            xlabel = show_lost_panel ? "" : "Mission time",
            ylabel = "Received data batches",
            xticks = (tick_vals_h, tick_labels),
        )
        xlims!(ax2, 0, max_x_h)
        max_gnd = maximum(df.Ground_Archive)
        ylims!(ax2, 0, max(10.0, 1.2 * max_gnd))

        shade_disruptions!(ax2, 0.0, max_x_h)
        shade_outages!(ax2, 0.0, max_x_h)

        band!(
            ax2,
            df_x,
            zeros(length(df_x)),
            Float64.(df.Ground_Archive),
            color = (COLOR_LIVE, 0.4),
        )
        stairs!(ax2, df_x, Float64.(df.Ground_Archive), color = COLOR_LIVE)

        band!(
            ax2,
            df_x,
            zeros(length(df_x)),
            Float64.(df.Ground_Arch),
            color = (COLOR_ARCHIVE, 0.4),
        )
        stairs!(ax2, df_x, Float64.(df.Ground_Arch), color = COLOR_ARCHIVE)

        # Dedicated Lost strip: rare discrete events get their own small
        # linear axis instead of an invisible flat line under the received
        # bands.
        axes_to_link = [ax1, ax2]
        if show_lost_panel
            # LinearTicks(3): the strip is ~1/3 panel height, so the default
            # automatic ticks crowd together once losses reach double digits.
            ax3 = Axis(
                fig_global[3, 1],
                xlabel = "Mission time",
                ylabel = "Lost",
                xticks = (tick_vals_h, tick_labels),
                yticks = LinearTicks(3),
            )
            rowsize!(fig_global.layout, 3, Auto(0.32))
            xlims!(ax3, 0, max_x_h)
            lost_curve = has_loss_cols ? Float64.(df.Lost_Count) : zeros(length(df_x))
            ylims!(ax3, 0, max(4.0, 1.35 * maximum(lost_curve)))
            shade_disruptions!(ax3, 0.0, max_x_h)
            shade_outages!(ax3, 0.0, max_x_h)
            stairs!(ax3, df_x, lost_curve, color = COLOR_LOST)
            inc = [i for i in 2:length(lost_curve) if lost_curve[i] > lost_curve[i-1]]
            scatter!(
                ax3,
                df_x[inc],
                lost_curve[inc],
                marker = :xcross,
                color = COLOR_LOST,
                markersize = PlotTheme.MARKERSIZE_DATA,
            )
            if lost_curve[end] > 0
                pct =
                    100 * lost_curve[end] /
                    max(1.0, Float64(df.Ground_Archive[end]) + lost_curve[end])
                text!(
                    ax3,
                    0.985,
                    0.88,
                    text = "$(Int(lost_curve[end])) lost ($(round(pct, digits=2)) %)",
                    space = :relative,
                    align = (:right, :top),
                    fontsize = PlotTheme.FONTSIZE_ANNOTATION,
                    color = COLOR_LOST,
                )
            end
            push!(axes_to_link, ax3)
            hidexdecorations!(ax2, grid = false, ticks = false)
        end
        hidexdecorations!(ax1, grid = false, ticks = false)

        # One aligned label column: reserve equal tick-label width on all
        # stacked axes (the Lost strip's 1-digit ticks would otherwise pull
        # its ylabel inward relative to the 4-digit panels above).
        foreach(ax -> ax.yticklabelspace = 34.0, axes_to_link)

        add_figure_legend!(
            fig_global;
            degraded = show_nominal,
            blackout = blackout_in(0.0, max_x_h),
            ramp = ramp_in(0.0, max_x_h),
            outage = outage_in(0.0, max_x_h),
            lost = show_lost_panel ? :strip : :none,
        )
        linkxaxes!(axes_to_link...)

        global_path = joinpath(run_dir, "plots", "mission_summary_global.png")
        save(global_path, fig_global, px_per_unit = 4)
        save(splitext(global_path)[1] * ".pdf", fig_global)
        @info "[RECEIVER] Saved Global Summary Plot: $(relpath(global_path, run_dir))"

        # 2. One session plot per mission day, enumerated from the NOMINAL
        # daily DSN window — not detected from effective bandwidth. A fully
        # blacked-out session therefore still receives its zero-throughput
        # plot — dotted nominal vs flat-zero effective, full shading, rising
        # buffer — so multi-day downtime spans the same days here as on the
        # summary, and file names share the summary's 0-based day coordinates.
        n_days = ceil(Int, max_x_h / 24.0)
        for day_k in 0:(n_days-1)
            min_sess_dt = DateTime(Date(t_start_dt + Day(day_k)), session_start_time)
            max_sess_dt = min_sess_dt + session_dur
            # Skip windows entirely outside the recorded mission span
            (to_h(max_sess_dt) <= 0.0 || to_h(min_sess_dt) >= max_x_h) && continue

            in_window = (df.SimTime .>= min_sess_dt) .& (df.SimTime .<= max_sess_dt)
            session_df = df[in_window, :]
            if length(session_df.SimTime) < 2
                continue
            end

            min_sess_h = to_h(min_sess_dt)
            max_sess_h = to_h(max_sess_dt)

            t_smooth_dt = [
                min_sess_dt + Millisecond(round(Int, (j-1)*session_dur.value*1000/199))
                for j in 1:200
            ]
            t_smooth_h = to_h.(t_smooth_dt)
            bw_smooth = Float64[
                100.0 * ChannelEffects.effective_bandwidth(link_model, t) for
                t in t_smooth_dt
            ]
            bw_nominal_smooth = Float64[
                100.0 * TelemetryCore.get_bandwidth_factor(vis_model, t) for
                t in t_smooth_dt
            ]
            sess_degraded = maximum(abs.(bw_nominal_smooth .- bw_smooth)) > 0.1

            tick_start_dt = Dates.floor(min_sess_dt, Hour(1))
            session_tick_vals_dt = collect(tick_start_dt:Hour(1):max_sess_dt)
            session_tick_vals_h = to_h.(session_tick_vals_dt)
            session_tick_labels = [Dates.format(t, "HH:MM") for t in session_tick_vals_dt]

            session_hours = to_h.(session_df.SimTime)
            plot_x = Float64[min_sess_h; session_hours; max_sess_h]
            plot_gnd = Float64[
                0.0;
                session_df.Ground_Archive .- session_df.Ground_Archive[1];
                session_df.Ground_Archive[end] - session_df.Ground_Archive[1]
            ]
            plot_gnd_arch = Float64[
                0.0;
                session_df.Ground_Arch .- session_df.Ground_Arch[1];
                session_df.Ground_Arch[end] - session_df.Ground_Arch[1]
            ]

            fig_sess = Figure(size = PlotTheme.FIG_SIZE_SESSION, figure_padding = 10)

            ax_s1 = Axis(
                fig_sess[1, 1],
                xlabel = "",
                ylabel = "Bandwidth [%]",
                xticks = (session_tick_vals_h, session_tick_labels),
            )
            xlims!(ax_s1, min_sess_h, max_sess_h)
            ylims!(ax_s1, 0, 105)

            ax_s1_twin = Axis(
                fig_sess[1, 1],
                yaxisposition = :right,
                ylabel = "Buffered data batches",
                yticklabelcolor = COLOR_ONBOARD,
            )
            hidespines!(ax_s1_twin)
            hidexdecorations!(ax_s1_twin)
            xlims!(ax_s1_twin, min_sess_h, max_sess_h)

            max_sess_onb = maximum(session_df.Onboard_Buffer)
            ylims!(ax_s1_twin, 0, max(10.0, 1.3 * max_sess_onb))

            shade_disruptions!(ax_s1, min_sess_h, max_sess_h)
            shade_outages!(ax_s1, min_sess_h, max_sess_h)
            if sess_degraded
                lines!(
                    ax_s1,
                    t_smooth_h,
                    bw_nominal_smooth,
                    color = (COLOR_BANDWIDTH, 0.35),
                    linestyle = :dot,
                )
            end
            lines!(ax_s1, t_smooth_h, bw_smooth, color = COLOR_BANDWIDTH)
            lines!(
                ax_s1_twin,
                session_hours,
                Float64.(session_df.Onboard_Buffer),
                color = COLOR_ONBOARD,
                linestyle = :dash,
            )

            ax_s2 = Axis(
                fig_sess[2, 1],
                xlabel = "Mission time",
                ylabel = "Received data batches",
                xticks = (session_tick_vals_h, session_tick_labels),
                # HH:MM labels crowd at session resolution; rotation is
                # applied here rather than in the global theme (rule:
                # rotate crowded labels only).
                xticklabelrotation = π / 4,
            )
            xlims!(ax_s2, min_sess_h, max_sess_h)
            max_sess_gnd = maximum(plot_gnd)
            y_max_s2 = max(10.0, 1.2 * max_sess_gnd)
            ylims!(ax_s2, 0, y_max_s2)

            shade_disruptions!(ax_s2, min_sess_h, max_sess_h)
            shade_outages!(ax_s2, min_sess_h, max_sess_h)

            band!(ax_s2, plot_x, zeros(length(plot_x)), plot_gnd, color = (COLOR_LIVE, 0.4))
            stairs!(ax_s2, plot_x, plot_gnd, color = COLOR_LIVE)

            band!(
                ax_s2,
                plot_x,
                zeros(length(plot_x)),
                plot_gnd_arch,
                color = (COLOR_ARCHIVE, 0.4),
            )
            stairs!(ax_s2, plot_x, plot_gnd_arch, color = COLOR_ARCHIVE)

            # Session losses: no dedicated panel (it would sit empty on
            # loss-free days) — ✕ markers along the top edge at the loss
            # instants plus a corner count annotation, and no elements at all
            # when the session lost nothing.
            n_lost_sess =
                has_loss_cols ? Int(session_df.Lost_Count[end] - session_df.Lost_Count[1]) :
                0
            if n_lost_sess > 0
                inc = [
                    j for j in 2:nrow(session_df) if
                    session_df.Lost_Count[j] > session_df.Lost_Count[j-1]
                ]
                scatter!(
                    ax_s2,
                    session_hours[inc],
                    fill(0.93 * y_max_s2, length(inc)),
                    marker = :xcross,
                    color = COLOR_LOST,
                    markersize = PlotTheme.MARKERSIZE_DATA,
                )
                text!(
                    ax_s2,
                    0.985,
                    0.985,
                    text = "$n_lost_sess lost this session",
                    space = :relative,
                    align = (:right, :top),
                    fontsize = PlotTheme.FONTSIZE_ANNOTATION,
                    color = COLOR_LOST,
                )
            end

            hidexdecorations!(ax_s1, grid = false, ticks = false)
            foreach(ax -> ax.yticklabelspace = 34.0, (ax_s1, ax_s2))

            add_figure_legend!(
                fig_sess;
                degraded = sess_degraded,
                blackout = blackout_in(min_sess_h, max_sess_h),
                ramp = ramp_in(min_sess_h, max_sess_h),
                outage = outage_in(min_sess_h, max_sess_h),
                lost = n_lost_sess > 0 ? :marks : :none,
            )
            linkxaxes!(ax_s1, ax_s2)

            session_path =
                joinpath(run_dir, "plots", "session_day$(lpad(day_k, 2, '0'))_detail.png")
            save(session_path, fig_sess, px_per_unit = 4)
            save(splitext(session_path)[1] * ".pdf", fig_sess)
        end
        @info "[RECEIVER] Saved Session-specific plots."
    end
end

"""
    BatchStates

Alias for the per-snapshot batch-location record shared by the mask generator
and the GIF animation: batch-ID vectors for every (stage × stream) bucket plus
the terminal `lost` bucket.
"""
const BatchStates = NamedTuple{
    (:onb_live, :onb_arch, :lnk_live, :lnk_arch, :gnd_live, :gnd_arch, :lost),
    NTuple{7,Vector{Int}},
}

"""
    reconstruct_batch_states(df::DataFrame, vis_model::TelemetryCore.VisibilityModel)

Replays the LIFO/FIFO transmission state machine over a `mission_profile.csv`
DataFrame. Returns a vector with one entry per profile row; each entry is a
[`BatchStates`](@ref) record describing where every batch resided at that
snapshot.

This reconstruction is heuristic: it infers batch identity from count deltas
between snapshots and cannot attribute packet losses, so its `lost` bucket is
always empty. It remains only as a fallback for legacy runs; runs that carry
`events_tx.csv` / `events_rx.csv` use the exact
[`reconstruct_batch_states_exact`](@ref) instead (see [`batch_states`](@ref)).
"""
function reconstruct_batch_states(df::DataFrame, vis_model::TelemetryCore.VisibilityModel)
    onb_live = Int[]
    onb_arch = Int[]
    lnk_live = Int[]
    lnk_arch = Int[]
    gnd_live = Int[]
    gnd_arch = Int[]

    states = Vector{BatchStates}(undef, 0)
    sizehint!(states, nrow(df))

    current_total = 0
    for i in 1:nrow(df)
        row = df[i, :]
        is_live = TelemetryCore.is_visible(vis_model, row.SimTime)

        # 1. Generate: new batches appear onboard; everything present in the
        #    very first snapshot stems from pre-populated (archived) downtime.
        total_i = row.Onboard_Buffer + row.Link_Buffer + row.Ground_Archive
        if total_i > current_total
            for id in (current_total+1):total_i
                if current_total == 0
                    push!(onb_arch, id)
                else
                    is_live ? push!(onb_live, id) : push!(onb_arch, id)
                end
            end
            current_total = total_i
        end

        # 2. Reconcile Ground (Live drains FIFO, Archive drains LIFO)
        while length(gnd_live) < row.Ground_Live
            if !isempty(lnk_live)
                push!(gnd_live, popfirst!(lnk_live))
            elseif !isempty(onb_live)
                push!(gnd_live, popfirst!(onb_live))
            else
                break
            end
        end
        while length(gnd_arch) < row.Ground_Arch
            if !isempty(lnk_arch)
                push!(gnd_arch, popfirst!(lnk_arch))
            elseif !isempty(onb_arch)
                push!(gnd_arch, pop!(onb_arch)) # LIFO
            else
                break
            end
        end

        # 3. Reconcile Link
        needed = row.Link_Buffer - (length(lnk_live) + length(lnk_arch))
        for _ in 1:needed
            if !isempty(onb_live)
                push!(lnk_live, popfirst!(onb_live))
            elseif !isempty(onb_arch)
                push!(lnk_arch, pop!(onb_arch)) # LIFO
            end
        end

        push!(
            states,
            (
                onb_live = copy(onb_live),
                onb_arch = copy(onb_arch),
                lnk_live = copy(lnk_live),
                lnk_arch = copy(lnk_arch),
                gnd_live = copy(gnd_live),
                gnd_arch = copy(gnd_arch),
                lost = Int[],
            ),
        )
    end
    return states
end

"""
    reconstruct_batch_states_exact(run_dir::String, df::DataFrame)

Exact replay of every batch's location from the ground-truth event logs
(`events_tx.csv`: `gen`/`tx` milestones written by the emitter;
`events_rx.csv`: `ingested`/`lost` milestones written by the receiver — the
state-preserving `retry` events are skipped). Returns one [`BatchStates`](@ref)
record per `mission_profile.csv` row, evaluated at that row's `SimTime`.

Unlike the count-delta heuristic this attributes each packet loss to its exact
batch ID, which is what makes mask state `4 = Lost` possible. Emitter and
receiver stamp milestones from separate clock reads, so recorded timestamps
can invert within a batch at high speed-up; the replay enforces per-batch
causal order (`gen` → `tx` → terminal) with later stages absorbing, keeping
every batch's state sequence monotone.
"""
function reconstruct_batch_states_exact(run_dir::String, df::DataFrame)
    tx = CSV.read(joinpath(run_dir, "events_tx.csv"), DataFrame)
    rx_path = joinpath(run_dir, "events_rx.csv")
    rx =
        isfile(rx_path) ? CSV.read(rx_path, DataFrame) :
        DataFrame(SimTime = DateTime[], Batch = String[], Event = String[], Attempt = Int[])

    # Chronological milestone list; the priority index breaks same-timestamp
    # ties in causal order (a batch is generated before it is transmitted,
    # transmitted before it is resolved). State-preserving events (`retry`:
    # the batch stays on the link; `pruned`: delivery already happened) are
    # skipped; unknown event names are tolerated with a warning so a newer
    # run's log never aborts an older toolchain's replay.
    event_rank = Dict("gen" => 1, "tx" => 2, "ingested" => 3, "lost" => 3)
    events = Vector{Tuple{DateTime,Int,String,String}}()
    for r in eachrow(tx)
        r.Event in ("gap_start", "gap_end") && continue # stream-level outage bounds
        if !haskey(event_rank, r.Event)
            @warn "[POST] Skipping unknown event \"$(r.Event)\" in events_tx.csv." maxlog =
                1
            continue
        end
        push!(events, (r.SimTime, event_rank[r.Event], String(r.Batch), String(r.Event)))
    end
    for r in eachrow(rx)
        r.Event in ("retry", "pruned") && continue
        if !haskey(event_rank, r.Event)
            @warn "[POST] Skipping unknown event \"$(r.Event)\" in events_rx.csv." maxlog =
                1
            continue
        end
        push!(events, (r.SimTime, event_rank[r.Event], String(r.Batch), String(r.Event)))
    end
    sort!(events, by = e -> (e[1], e[2]))

    # Category vectors plus a batch-ID → (category, index) position map:
    # every event application is O(1) via swap-remove, replacing the former
    # per-event `filter!` scans that made the replay quadratic over a
    # mission. Order within a category is not part of the contract (masks
    # index by batch ID; scatters are unordered).
    category = Dict(
        :onb_live => Int[],
        :onb_arch => Int[],
        :lnk_live => Int[],
        :lnk_arch => Int[],
        :gnd_live => Int[],
        :gnd_arch => Int[],
        :lost => Int[],
    )
    position = Dict{Int,Tuple{Symbol,Int}}()

    # Swap-remove `id` from its current category (no-op for an unseen ID,
    # e.g. a truncated log whose `gen` row is missing).
    displace! = id -> begin
        loc = get(position, id, nothing)
        loc === nothing && return nothing
        (cat, idx) = loc
        v = category[cat]
        moved = v[end]
        v[idx] = moved
        position[moved] = (cat, idx)
        pop!(v)
        delete!(position, id)
        return nothing
    end
    # Causal stage rank: emitter and receiver stamp events from separate
    # clock reads, so at high speed-up a batch's `ingested` record can carry
    # an earlier timestamp than its own `tx` record. Per-batch causality
    # (gen < tx < terminal) outranks recorded timestamps: a later-stage
    # placement is absorbing and an earlier-stage event arriving late is
    # dropped.
    stage_rank = Dict(
        :onb_live => 1,
        :onb_arch => 1,
        :lnk_live => 2,
        :lnk_arch => 2,
        :gnd_live => 3,
        :gnd_arch => 3,
        :lost => 4,
    )
    # Move `id` into `cat`; self-cleaning, so a duplicated log row can
    # never strand a stale copy in a previous category.
    place! =
        (id, cat) -> begin
            loc = get(position, id, nothing)
            loc !== nothing && stage_rank[loc[1]] >= stage_rank[cat] && return nothing
            displace!(id)
            v = category[cat]
            push!(v, id)
            position[id] = (cat, length(v))
            return nothing
        end

    states = Vector{BatchStates}(undef, 0)
    sizehint!(states, nrow(df))

    ev_idx = 1
    for i in 1:nrow(df)
        t = df.SimTime[i]
        while ev_idx <= length(events) && events[ev_idx][1] <= t
            (_, _, name, kind) = events[ev_idx]
            id = TelemetryCore.batch_id(name)
            is_live = TelemetryCore.is_live_batch(name)
            if kind == "gen"
                place!(id, is_live ? :onb_live : :onb_arch)
            elseif kind == "tx"
                place!(id, is_live ? :lnk_live : :lnk_arch)
            elseif kind == "ingested"
                place!(id, is_live ? :gnd_live : :gnd_arch)
            elseif kind == "lost"
                place!(id, :lost)
            end
            ev_idx += 1
        end
        push!(
            states,
            (
                onb_live = copy(category[:onb_live]),
                onb_arch = copy(category[:onb_arch]),
                lnk_live = copy(category[:lnk_live]),
                lnk_arch = copy(category[:lnk_arch]),
                gnd_live = copy(category[:gnd_live]),
                gnd_arch = copy(category[:gnd_arch]),
                lost = copy(category[:lost]),
            ),
        )
    end
    return states
end

"""
    batch_states(run_dir::String, df::DataFrame, vis_model::TelemetryCore.VisibilityModel)

Dispatcher for the batch-state reconstruction: exact event-log replay
([`reconstruct_batch_states_exact`](@ref)) whenever `events_tx.csv` exists in
`run_dir`, count-delta heuristic ([`reconstruct_batch_states`](@ref))
otherwise (legacy runs).
"""
function batch_states(
    run_dir::String,
    df::DataFrame,
    vis_model::TelemetryCore.VisibilityModel,
)
    if isfile(joinpath(run_dir, "events_tx.csv"))
        return reconstruct_batch_states_exact(run_dir, df)
    end
    return reconstruct_batch_states(df, vis_model)
end

"""
    generate_telemetry_masks(run_dir::String)

A post-processing utility that reconstructs the LIFO/FIFO transmission state
machine (exactly, from the event logs, when available — see
[`batch_states`](@ref)). It outputs a 2D matrix `telemetry_mask_timeline.csv`
where rows are time steps and columns are specific `Batch_ID`s, indicating
their exact physical location (0=Future, 1=Onboard, 2=Link, 3=Ground,
4=Lost).
"""
function generate_telemetry_masks(run_dir::String)
    log_path = joinpath(run_dir, "mission_profile.csv")
    if !isfile(log_path)
        @warn "[POST] mission_profile.csv missing in $run_dir — the receiver produced no metrics (component never ran?); skipping this product."
        return
    end

    df = CSV.read(log_path, DataFrame)
    if isempty(df)
        return
    end

    cfg = TelemetryCore.load_run_config(run_dir)
    tel_settings = TelemetryCore.telemetry_settings(cfg)
    session_start_time = tel_settings.session_start
    session_dur = tel_settings.session_duration
    vis_model = TelemetryCore.visibility_model(cfg)

    states = batch_states(run_dir, df, vis_model)
    # True maximum batch ID, not the batch count: the ID space may carry
    # holes (truncated logs, hand-assembled or reconciled run directories),
    # and a count-sized matrix would fault on the first such hole.
    max_id_ever =
        isempty(states) ? 0 : maximum(cat -> isempty(cat) ? 0 : maximum(cat), last(states))

    # 0 = Future, 1 = Onboard, 2 = Link, 3 = Ground, 4 = Lost
    mask_matrix = zeros(Int8, nrow(df), max_id_ever)

    for (i, st) in enumerate(states),
        (code, cats) in (
            (Int8(1), (st.onb_live, st.onb_arch)),
            (Int8(2), (st.lnk_live, st.lnk_arch)),
            (Int8(3), (st.gnd_live, st.gnd_arch)),
            (Int8(4), (st.lost,)),
        )

        for cat in cats, id in cat
            # Unparsable batch names replay as ID 0 — excluded from the
            # matrix rather than faulting the whole product.
            1 <= id <= max_id_ever && (mask_matrix[i, id] = code)
        end
    end

    # Construct DataFrame
    mask_df = DataFrame(SimTime = df.SimTime)
    for id in 1:max_id_ever
        mask_df[!, Symbol("Batch_$id")] = mask_matrix[:, id]
    end

    mask_path = joinpath(run_dir, "masks", "telemetry_mask_timeline.csv")
    TelemetryCore.safe_csv_write(mask_path, mask_df)
    @info "[RECEIVER] Saved 2D telemetry data masks to: $(relpath(mask_path, run_dir))"

    # Batch → epoch sidecar: the point-wise mask's row-index contract assumes
    # a contiguous series, which emitter outages break; this map lets
    # consumers re-anchor batch rows on the mission timeline. `GenSimTime` is
    # the finalization (transmittable) instant from the event log;
    # `ContentEpoch` is the first-sample timestamp of the payload from each
    # batch's metadata (missing for batches written before that key existed).
    tx_path = joinpath(run_dir, "events_tx.csv")
    if isfile(tx_path)
        tx_events = CSV.read(tx_path, DataFrame)
        gens = tx_events[tx_events.Event .== "gen", :]
        if !isempty(gens)
            content = TelemetryCore.batch_content_epochs(run_dir)
            epochs = DataFrame(
                Batch = gens.Batch,
                GenSimTime = gens.SimTime,
                ContentEpoch = [get(content, String(b), missing) for b in gens.Batch],
            )
            TelemetryCore.safe_csv_write(
                joinpath(run_dir, "masks", "batch_epochs.csv"),
                epochs,
            )
        end
    end
end

"""
    delivered_payload_queue(run_dir::String, ground_path::String)
        -> Vector{Tuple{DateTime,String,Int}}

Materializes the retention custodian's pruning queue from the run's ground
census and `events_rx.csv`: delivered (`ingested`) batches whose payload has
not been `pruned`, oldest-ingested first, each with its current `seg_*.csv`
payload size in bytes. Consulted at startup for the payload tally and lazily
on watermark breach, so the in-memory queue stays empty outside breach
episodes.
"""
function delivered_payload_queue(run_dir::String, ground_path::String)
    rx_log_path = joinpath(run_dir, "events_rx.csv")
    isfile(rx_log_path) || return Tuple{DateTime,String,Int}[]
    rx_hist = CSV.read(rx_log_path, DataFrame)
    isempty(rx_hist) && return Tuple{DateTime,String,Int}[]
    ingested_t = Dict(
        String(r.Batch) => r.SimTime for r in eachrow(rx_hist) if r.Event == "ingested"
    )
    pruned_set = Set(String(r.Batch) for r in eachrow(rx_hist) if r.Event == "pruned")
    ground_names = filter(f -> isdir(joinpath(ground_path, f)), readdir(ground_path))
    survivors = sort!(
        [b for b in ground_names if haskey(ingested_t, b) && !(b in pruned_set)];
        by = b -> ingested_t[b],
    )
    queue = Tuple{DateTime,String,Int}[]
    for b in survivors
        bdir = joinpath(ground_path, b)
        payload = sum(
            f -> startswith(f, "seg_") ? Int(filesize(joinpath(bdir, f))) : 0,
            readdir(bdir);
            init = 0,
        )
        push!(queue, (ingested_t[b], b, payload))
    end
    return queue
end

# --- Receiver Main Loop ---
"""
    run_receiver(clock, link, run_id; ...)

The main ground-station loop. It continually checks the `link/` directory for
incoming data batches, simulates a delay based on the effective link capacity
(visibility profile × disruption factor), draws a stochastic loss realization
per transfer attempt from `loss_model`, moves successful batches to `ground/`
and exhausted ones to `lost/`, and outputs real-time dashboard metrics
directly to the `stdout` buffer.

A lost transfer leaves the batch on the link (head-of-line blocking, a real
property of priority downlink protocols) and is retried on the next pass; after
`max_retries` failed attempts the batch is moved to `lost/` — never deleted —
which frees the emitter's transmission window slot (in-flight occupancy is
the `link/` listing). Every
milestone is appended to `events_rx.csv` for exact post-processing
reconstruction. At startup, a re-attaching receiver reseeds retry and
custodial state from the event log and synthesizes `ingested` records (at the
re-attach instant) for batches delivered to `ground/` whose record was lost
to a crash between the delivery move and the log append.

When `retention.enabled` the loop also runs the retention custodian: once the
delivered-payload tally exceeds `watermark_bytes`, the oldest-ingested batches
beyond the `grace` mission-time guarantee have their `seg_*.csv` payload
files deleted — the batch directory keeps `metadata.json`, gains a `PRUNED`
marker, and a `pruned` event is appended to `events_rx.csv`. Event logs,
metrics, masks, and `lost/` are never pruned. The pruning queue is
materialized lazily on watermark breach ([`delivered_payload_queue`](@ref)).

# Keyword arguments

  - `orig_stdout`: stream receiving the dashboard rendering.
  - `max_batches_per_hour`: peak DSN service capacity [batches/h].
  - `loss_model`: stochastic packet-loss channel (`ChannelEffects.LossModel`).
  - `max_retries`: failed attempts before a batch moves to `lost/`.
  - `retention`: the custodian's [`TelemetryCore.RetentionPolicy`](@ref).
  - `deadline`: absolute wall-clock stop shared by both components.
  - `stop`: cooperative stop flag raised by the supervisor.
  - `heartbeat_path`: liveness file touched once per second when set.
  - `min_link_factor`: capacity floor below which no transfer is attempted.
"""
function run_receiver(
    clock::TelemetryCore.SimulationClock,
    link::ChannelEffects.LinkModel,
    run_id::String;
    orig_stdout::IO = stdout,
    max_batches_per_hour::Float64 = 20.0,
    loss_model::ChannelEffects.LossModel = ChannelEffects.NoLoss(),
    max_retries::Int = 3,
    retention::TelemetryCore.RetentionPolicy = TelemetryCore.retention_settings(
        Dict{String,Any}(),
    ),
    deadline::Union{DateTime,Nothing} = nothing,
    stop::Union{Threads.Atomic{Bool},Nothing} = nothing,
    heartbeat_path::Union{String,Nothing} = nothing,
    min_link_factor::Float64 = 0.05,
)
    run_dir = TelemetryCore.run_directory(run_id)
    link_path = joinpath(run_dir, "link")
    onboard_path = joinpath(run_dir, "onboard")
    ground_path = joinpath(run_dir, "ground")
    lost_path = joinpath(run_dir, "lost")
    foreach(mkpath, (link_path, onboard_path, ground_path, lost_path)) # idempotent

    halt_path = joinpath(run_dir, "HALT")
    last_heartbeat = now() - Second(2)

    last_onboard = -1
    last_link = -1
    last_ground = -1
    last_lost = -1
    last_bw = -1.0

    retry_counts = Dict{String,Int}() # failed attempts per in-flight batch
    total_retries = 0

    # Ground and lost counters are receiver-owned (only this loop moves batches
    # into those directories), so they are tracked incrementally after a single
    # startup census: a per-tick readdir over ground/ is O(archive size) and
    # measurably throttles the ingest rate on long missions.
    ground_seed = filter(f -> isdir(joinpath(ground_path, f)), readdir(ground_path))
    ground_live = count(TelemetryCore.is_live_batch, ground_seed)
    ground_arch = count(TelemetryCore.is_archive_batch, ground_seed)
    lost_count = length(filter(f -> isdir(joinpath(lost_path, f)), readdir(lost_path)))

    # Retention custodian state: FIFO of delivered batches (ingest sim-time,
    # name, payload bytes) and the running prunable-payload tally the
    # watermark is compared against.
    prune_queue = Vector{Tuple{DateTime,String,Int}}()
    ground_payload_bytes = 0

    # Re-attach seeding + delivery reconciliation from the event log: a
    # restarted receiver must not grant fresh retry budgets to in-flight
    # batches nor forget custodial state, and batches present in ground/
    # without an ingested record witness a crash between delivery and
    # logging (they remain in-transit in the mask replay).
    rx_log_path = joinpath(run_dir, "events_rx.csv")
    if isfile(rx_log_path)
        rx_hist = CSV.read(rx_log_path, DataFrame)
        if !isempty(rx_hist)
            total_retries = count(==("retry"), rx_hist.Event)
            pending = Set(filter(f -> isdir(joinpath(link_path, f)), readdir(link_path)))
            for r in eachrow(rx_hist)
                r.Event == "retry" &&
                    r.Batch in pending &&
                    (retry_counts[r.Batch] = get(retry_counts, r.Batch, 0) + 1)
            end
            ingested_t = Dict(
                String(r.Batch) => r.SimTime for
                r in eachrow(rx_hist) if r.Event == "ingested"
            )
            unrecorded = sort!(collect(setdiff(Set(ground_seed), keys(ingested_t))))
            if !isempty(unrecorded)
                # Reconciliation synthesis: a batch present in ground/ without
                # an ingested record witnesses a crash between the delivery
                # move and the log append. The actual delivery time is
                # unrecoverable, so the record is synthesized at the re-attach
                # instant — masks, custodian, and consumers then agree the
                # batch is delivered.
                reconcile_t = TelemetryCore.get_current_sim_time(clock)
                for b in unrecorded
                    TelemetryCore.log_rx_event(run_dir, reconcile_t, b, "ingested", 0)
                    ingested_t[b] = reconcile_t
                end
                @warn "[RECEIVER] Re-attach: synthesized ingested records at $reconcile_t for $(length(unrecorded)) batches present in ground/ without a delivery record (crash window between delivery and logging)." batches =
                    first(unrecorded, min(5, length(unrecorded)))
            end
            if retention.enabled
                # Tally only: the prune queue itself is materialized lazily on
                # watermark breach (see the custodian block below), so it stays
                # empty on missions whose watermark is never reached.
                ground_payload_bytes = sum(
                    entry -> entry[3],
                    delivered_payload_queue(run_dir, ground_path);
                    init = 0,
                )
            end
        end
    end

    @info "Initializing Receiver Dashboard..."

    try
        while true
            if stop !== nothing && stop[]
                @info "[RECEIVER] Stop signal received. Shutting down."
                break
            end
            if isfile(halt_path)
                @info "[RECEIVER] HALT sentinel detected. Shutting down."
                break
            end
            if deadline !== nothing && now() >= deadline
                break
            end
            if heartbeat_path !== nothing && (now() - last_heartbeat).value >= 1000
                touch(heartbeat_path)
                last_heartbeat = now()
            end

            sim_t = TelemetryCore.get_current_sim_time(clock)
            nominal_factor = TelemetryCore.get_bandwidth_factor(link.visibility, sim_t)
            disruption_scale = ChannelEffects.disruption_factor(link.disruptions, sim_t)
            bw_factor = nominal_factor * disruption_scale
            hours_elapsed = (sim_t - clock.start_sim_time).value / (1000 * 3600)
            bandwidth_pct = bw_factor * 100
            nominal_pct = nominal_factor * 100
            disruption_active = disruption_scale < 1.0

            onboard_count =
                length(filter(f -> isdir(joinpath(onboard_path, f)), readdir(onboard_path)))
            link_count =
                length(filter(f -> isdir(joinpath(link_path, f)), readdir(link_path)))
            ground_count = ground_live + ground_arch

            if onboard_count != last_onboard ||
               link_count != last_link ||
               ground_count != last_ground ||
               lost_count != last_lost ||
               abs(bandwidth_pct - last_bw) > TelemetryCore.METRICS_BANDWIDTH_HYSTERESIS_PCT
                metrics = TelemetryCore.MissionMetrics(
                    sim_t,
                    now(),
                    hours_elapsed,
                    bandwidth_pct,
                    onboard_count,
                    link_count,
                    ground_count,
                    ground_live,
                    ground_arch,
                    nominal_pct,
                    lost_count,
                    total_retries,
                    disruption_active,
                )
                TelemetryCore.save_metrics(run_dir, metrics)

                last_onboard = onboard_count
                last_link = link_count
                last_ground = ground_count
                last_lost = lost_count
                last_bw = bandwidth_pct
            end

            # Retention custodian: prune delivered payload CSVs oldest-first
            # once the prunable tally exceeds the watermark — but never within
            # the grace window, which is the availability guarantee consumers
            # rely on (docs/src/interfaces.md). Only seg_*.csv files are
            # deleted; metadata.json stays and a PRUNED marker plus a `pruned`
            # event record the action.
            if retention.enabled && ground_payload_bytes > retention.watermark_bytes
                # Materialized on breach and refreshed when exhausted
                # mid-breach; empty between breach episodes (bounded growth).
                isempty(prune_queue) &&
                    append!(prune_queue, delivered_payload_queue(run_dir, ground_path))
                while ground_payload_bytes > retention.watermark_bytes &&
                      !isempty(prune_queue) &&
                      (sim_t - prune_queue[1][1]) >= retention.grace
                    (ingest_t, pruned_name, payload_bytes) = popfirst!(prune_queue)
                    batch_dir = joinpath(ground_path, pruned_name)
                    try
                        for f in readdir(batch_dir)
                            startswith(f, "seg_") &&
                                rm(joinpath(batch_dir, f); force = true)
                        end
                        touch(joinpath(batch_dir, "PRUNED"))
                        TelemetryCore.log_rx_event(run_dir, sim_t, pruned_name, "pruned", 0)
                        @info "[RECEIVER] Retention: pruned payload of $pruned_name (ingested $ingest_t)"
                        # Decrement only on success: after a failed prune the
                        # files are still on disk and the tally must stay
                        # truthful (the batch is not re-queued; logged above).
                        ground_payload_bytes -= payload_bytes
                    catch e
                        @error "[RECEIVER] Retention pruning failed for $pruned_name — continuing." exception =
                            e
                    end
                end
            end

            status_text = if disruption_active && nominal_factor > 0.0
                ev_label = ChannelEffects.active_disruption_label(link.disruptions, sim_t)
                ev_name = isempty(ev_label) ? "DISRUPTION" : uppercase(ev_label)
                disruption_scale == 0.0 ? "$ev_name (Link down)" :
                "$ev_name RECOVERY (Link: $(round(bandwidth_pct, digits=1))%)"
            elseif bw_factor > 0.0
                "ACTIVE (Link: $(round(bandwidth_pct, digits=1))%)"
            else
                "DORMANT (Out of window)"
            end
            dashboard_text =
                "\e[H\e[J" *
                "="^55 *
                "\n" *
                lpad("DEEP-SPACE TELEMETRY DASHBOARD", 42) *
                "\n" *
                "="^55 *
                "\n" *
                rpad("Mission Day:", 20) *
                "$(round(hours_elapsed / 24.0, digits=2))\n" *
                rpad("Current Status:", 20) *
                "$status_text\n" *
                rpad("Ground total:", 20) *
                "$ground_count received data batches\n" *
                rpad("Lost Batches:", 20) *
                "$lost_count ($total_retries failed transfers)\n" *
                "="^55 *
                "\n"
            print(orig_stdout, dashboard_text)
            flush(orig_stdout)

            pending_batches = filter(
                f -> TelemetryCore.is_batch_name(f) && isdir(joinpath(link_path, f)),
                readdir(link_path),
            )

            if !isempty(pending_batches) && bw_factor > min_link_factor
                # LIVE before ARCH; within LIVE oldest-first (FIFO), within ARCH
                # newest-first (LIFO). Plain lexicographic readdir order would
                # scramble numeric IDs (e.g. batch_29 before batch_31).
                sort!(
                    pending_batches,
                    by = x -> begin
                        id = TelemetryCore.batch_id(x)
                        TelemetryCore.is_live_batch(x) ? (0, id) : (1, -id)
                    end,
                )
                batch_name = first(pending_batches)

                nominal_slot_sec = (3600.0 / max_batches_per_hour)
                effective_slot_sec = nominal_slot_sec / (bw_factor * clock.speed_up)
                sleep(max(TelemetryCore.RECEIVER_SLEEP_FLOOR_SEC, effective_slot_sec))

                loss_mult =
                    ChannelEffects.disruption_loss_multiplier(link.disruptions, sim_t)
                if ChannelEffects.sample_loss!(loss_model; multiplier = loss_mult)
                    attempts = get(retry_counts, batch_name, 0) + 1
                    retry_counts[batch_name] = attempts
                    total_retries += 1
                    if attempts > max_retries
                        # Retry budget exhausted: preserve the data in lost/;
                        # leaving link/ frees the emitter's window slot.
                        TelemetryCore.backup_existing_dir(joinpath(lost_path, batch_name))
                        mv(joinpath(link_path, batch_name), joinpath(lost_path, batch_name))
                        delete!(retry_counts, batch_name)
                        lost_count += 1
                        TelemetryCore.log_rx_event(
                            run_dir,
                            sim_t,
                            batch_name,
                            "lost",
                            attempts,
                        )
                        @warn "[RECEIVER] LOST: $batch_name after $attempts failed transfers @ SimTime: $sim_t"
                    else
                        TelemetryCore.log_rx_event(
                            run_dir,
                            sim_t,
                            batch_name,
                            "retry",
                            attempts,
                        )
                        @info "[RECEIVER] Transfer failed ($attempts/$(max_retries + 1)): $batch_name — retrying"
                    end
                else
                    @info "[RECEIVER] Ingesting: $batch_name @ SimTime: $sim_t"
                    @info "Bandwidth: $(round(bandwidth_pct))% | Batches buffered: $onboard_count | Total Data Batches: $ground_count"

                    prior_attempts = get(retry_counts, batch_name, 0)
                    TelemetryCore.backup_existing_dir(joinpath(ground_path, batch_name))
                    mv(joinpath(link_path, batch_name), joinpath(ground_path, batch_name))
                    delete!(retry_counts, batch_name)
                    if TelemetryCore.is_live_batch(batch_name)
                        ground_live += 1
                    else
                        ground_arch += 1
                    end
                    TelemetryCore.log_rx_event(
                        run_dir,
                        sim_t,
                        batch_name,
                        "ingested",
                        prior_attempts,
                    )
                    if retention.enabled
                        batch_dir = joinpath(ground_path, batch_name)
                        payload = sum(
                            f ->
                                startswith(f, "seg_") ?
                                Int(filesize(joinpath(batch_dir, f))) : 0,
                            readdir(batch_dir);
                            init = 0,
                        )
                        # Tally only — the prune queue is materialized lazily
                        # on watermark breach (custodian block).
                        ground_payload_bytes += payload
                    end
                end
            else
                watch_folder(link_path, TelemetryCore.RECEIVER_POLL_INTERVAL_SEC)
            end
        end
    finally
        # Heartbeat exists only while the loop runs: removing it before the
        # (potentially slow) plot rendering tells the watchdog this component
        # finished rather than stalled.
        heartbeat_path !== nothing && rm(heartbeat_path; force = true)
        println(orig_stdout, "\n")
        # A plotting failure must never cost a completed run: the CSVs and
        # batch directories are already on disk and plots can be regenerated.
        try
            generate_mission_plots(run_dir)
        catch e
            @error "[RECEIVER] Plot generation failed — run data is intact; fix and re-call generate_mission_plots(run_dir)." exception =
                (e, catch_backtrace())
        end
    end
end

end # module Receiver
