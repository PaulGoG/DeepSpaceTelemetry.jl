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
using Dates: Dates, Date, DateTime, Day, Hour, Millisecond, Second, Time, now
using FileWatching: FileWatching, watch_folder

"""
    hours_since(t::DateTime, t0::DateTime) -> Float64

Elapsed mission hours from `t0` to `t` — the plot-coordinate transform of
every figure (time axes are anchored at `start_sim_time`, 0-based days).
"""
hours_since(t::DateTime, t0::DateTime) = Float64((t - t0).value) / (1000 * 3600)

"""
    PlotContext

Per-run inputs shared by the mission summary and the session figures: the
metrics frame with its elapsed-hour axis, the mission epoch, the nominal
session window, the visibility and link models, the disruption and
component-outage spans in plot coordinates, and the loss-panel policy.
Built once by [`plot_context`](@ref).
"""
struct PlotContext
    run_dir::String
    df::DataFrame
    df_x::Vector{Float64}
    t_start::DateTime
    session_start::Time
    session_duration::Second
    vis_model::TelemetryCore.VisibilityModel
    link_model::ChannelEffects.LinkModel
    disruption_spans::Vector{NTuple{3,Float64}} # (blackout start, blackout end, recovery end)
    outage_spans::Vector{NTuple{2,Float64}}     # component down → restart (or mission end)
    has_loss_cols::Bool
    show_lost_panel::Bool
end

"""
    component_outage_spans(run_dir, t_start, x_end) -> Vector{NTuple{2,Float64}}

Component-outage windows from the supervisor's `component_events.csv`: each
`down` opens a window closed by the next `restart` of the same component,
or by the mission end `x_end` [h]. Empty when the record is absent.
"""
function component_outage_spans(run_dir::String, t_start::DateTime, x_end::Float64)
    spans = NTuple{2,Float64}[]
    path = joinpath(run_dir, "component_events.csv")
    isfile(path) || return spans
    events = CSV.read(path, DataFrame)
    open_down = Dict{String,DateTime}()
    for r in eachrow(events)
        comp = String(r.Component)
        if r.Event == "down"
            open_down[comp] = r.SimTime
        elseif r.Event == "restart" && haskey(open_down, comp)
            push!(
                spans,
                (
                    hours_since(pop!(open_down, comp), t_start),
                    hours_since(r.SimTime, t_start),
                ),
            )
        end
    end
    for (_, t_down) in open_down
        push!(spans, (hours_since(t_down, t_start), x_end))
    end
    return spans
end

"""
    plot_context(run_dir::String, df::DataFrame, cfg::AbstractDict) -> PlotContext

Assembles the [`PlotContext`](@ref) of a run from its metrics frame and its
configuration snapshot. The time axis is anchored at `start_sim_time` — not
at the first metrics row, which lands whenever the receiver first flushes —
so day ticks and disruption shading sit exactly on mission-day boundaries;
a legacy or corrupt snapshot falls back to the first row. A malformed
disruption section warns and yields an empty timeline rather than aborting
the post-processing of an otherwise complete run.
"""
function plot_context(run_dir::String, df::DataFrame, cfg::AbstractDict)
    tel_settings = TelemetryCore.telemetry_settings(cfg)
    vis_model = TelemetryCore.visibility_model(cfg)
    sim = get(cfg, "simulation", Dict{String,Any}())
    disruptions = try
        haskey(sim, "start_sim_time") ?
        ChannelEffects.build_disruption_timeline(cfg, DateTime(sim["start_sim_time"])) :
        ChannelEffects.DisruptionTimeline()
    catch e
        @warn "[RECEIVER] Could not parse disruption events from the run snapshot; plotting without disruption shading." exception =
            e
        ChannelEffects.DisruptionTimeline()
    end
    sim_start = try
        DateTime(get(sim, "start_sim_time", ""))
    catch
        nothing
    end
    t_start = something(sim_start, df.SimTime[1])
    df_x = [hours_since(t, t_start) for t in df.SimTime]
    disruption_spans = [
        (
            hours_since(ev.start_time, t_start),
            hours_since(ev.blackout_end, t_start),
            hours_since(ev.recovery_end, t_start),
        ) for ev in disruptions.events
    ]
    has_loss_cols = hasproperty(df, :Lost_Count)
    any_lost = has_loss_cols && maximum(df.Lost_Count) > 0
    # The dedicated Lost strip renders whenever the loss channel was enabled —
    # an empty strip honestly reports "no losses" — and for legacy runs that
    # recorded losses without a config snapshot.
    loss_enabled = Bool(get(get(cfg, "packet_loss", Dict{String,Any}()), "enabled", false))
    return PlotContext(
        run_dir,
        df,
        df_x,
        t_start,
        tel_settings.session_start,
        tel_settings.session_duration,
        vis_model,
        ChannelEffects.LinkModel(vis_model, disruptions),
        disruption_spans,
        component_outage_spans(run_dir, t_start, maximum(df_x)),
        has_loss_cols,
        (loss_enabled && has_loss_cols) || any_lost,
    )
end

"""
    spans_overlap(spans, x_lo, x_hi, lo, hi) -> Bool

`true` when any span's `[s[lo], s[hi]]` phase intersects the plotted window
`[x_lo, x_hi]`. Legends must only advertise what their own figure draws, so
blackout (`lo = 1, hi = 2`) and recovery-ramp (`lo = 2, hi = 3`) phases are
gated independently.
"""
spans_overlap(spans, x_lo::Float64, x_hi::Float64, lo::Int, hi::Int) =
    any(s -> s[lo] < x_hi && s[hi] > x_lo, spans)

"""
    shade_outages!(ax, x_lo, x_hi, outage_spans)

Shades component-outage windows onto `ax`, clamped to the plotted range: a
neutral grey wash with dotted edge lines, pushed behind the data. Distinct
from the configured disruption shading — these are unscheduled
infrastructure outages.
"""
function shade_outages!(ax, x_lo::Float64, x_hi::Float64, outage_spans)
    for (o0, o1) in outage_spans
        o0c, o1c = max(o0, x_lo), min(o1, x_hi)
        o0c < o1c || continue
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
    return ax
end

"""
    shade_disruptions!(ax, x_lo, x_hi, disruption_spans)

Shades every disruption event onto `ax`, clamped to the plotted range: a
uniform wash over the blackout, fading linearly to zero alpha across the
recovery ramp (mirroring the capacity ramp), with dashed lines delimiting
event start and full recovery. All shading is pushed far back along z so it
renders behind the data identically on every panel — but strictly above
z = -100, where the white background of a twin axis (dual-y panels) would
cover it.
"""
function shade_disruptions!(ax, x_lo::Float64, x_hi::Float64, disruption_spans)
    for (b0, b1, r1) in disruption_spans
        b0c, b1c = max(b0, x_lo), min(b1, x_hi)
        if b0c < b1c
            v = vspan!(ax, b0c, b1c, color = (PlotTheme.COLOR_DISRUPTION, 0.18))
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
                    color = (PlotTheme.COLOR_DISRUPTION, fade),
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
    return ax
end

"""
    add_figure_legend!(fig; degraded, blackout, ramp, lost, outage = false)

One frameless horizontal legend strip above the panels of `fig`, with
composite fill+edge patches for the band+stair pairs. Entries are strictly
limited to what that figure draws: `degraded` swaps the single capacity
entry for the nominal/effective pair, `blackout`/`ramp`/`outage` gate the
shading patches, and `lost` is `:strip` (summary stairs + marks), `:marks`
(session ✕ pins), or `:none`.
"""
function add_figure_legend!(
    fig;
    degraded::Bool,
    blackout::Bool,
    ramp::Bool,
    lost::Symbol,
    outage::Bool = false,
)
    elems = Any[]
    labels = String[]
    if degraded
        push!(
            elems,
            LineElement(
                color = (PlotTheme.COLOR_BANDWIDTH, 0.5),
                linewidth = 2 * PlotTheme.LINEWIDTH_DATA,
                linestyle = :dot,
            ),
        )
        push!(labels, "Nominal capacity")
        push!(
            elems,
            LineElement(
                color = PlotTheme.COLOR_BANDWIDTH,
                linewidth = 2 * PlotTheme.LINEWIDTH_DATA,
            ),
        )
        push!(labels, "Effective capacity")
    else
        push!(
            elems,
            LineElement(
                color = PlotTheme.COLOR_BANDWIDTH,
                linewidth = 2 * PlotTheme.LINEWIDTH_DATA,
            ),
        )
        push!(labels, "Link capacity")
    end
    push!(
        elems,
        LineElement(
            color = PlotTheme.COLOR_ONBOARD,
            linewidth = 2 * PlotTheme.LINEWIDTH_DATA,
            linestyle = :dash,
        ),
    )
    push!(labels, "Onboard buffer")
    push!(
        elems,
        PolyElement(
            color = (PlotTheme.COLOR_LIVE, 0.4),
            strokecolor = PlotTheme.COLOR_LIVE,
            strokewidth = 3,
        ),
    )
    push!(labels, "Total received (live + archive)")
    push!(
        elems,
        PolyElement(
            color = (PlotTheme.COLOR_ARCHIVE, 0.4),
            strokecolor = PlotTheme.COLOR_ARCHIVE,
            strokewidth = 3,
        ),
    )
    push!(labels, "Archive backfill (LIFO)")
    if lost === :strip
        push!(
            elems,
            [
                LineElement(
                    color = PlotTheme.COLOR_LOST,
                    linewidth = 2 * PlotTheme.LINEWIDTH_DATA,
                ),
                MarkerElement(
                    marker = :xcross,
                    color = PlotTheme.COLOR_LOST,
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
                color = PlotTheme.COLOR_LOST,
                markersize = PlotTheme.MARKERSIZE_DATA,
            ),
        )
        push!(labels, "Lost")
    end
    if blackout
        push!(elems, PolyElement(color = (PlotTheme.COLOR_DISRUPTION, 0.18)))
        push!(labels, "Blackout")
    end
    if ramp
        push!(elems, PolyElement(color = (PlotTheme.COLOR_DISRUPTION, 0.08)))
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
    return fig
end

"""
    summary_tick_step_hours(total_days) -> Float64

Day-tick spacing of the mission summary [h]: daily up to 10 days, every
other day up to 45, monthly up to 200, bi-monthly beyond.
"""
function summary_tick_step_hours(total_days::Float64)
    total_days <= 10 && return 24.0
    total_days <= 45 && return 24.0 * 2
    total_days <= 200 && return 24.0 * 30
    return 24.0 * 60
end

"""
    plot_mission_summary(ctx::PlotContext) -> String

Renders the mission summary — capacity with the onboard buffer on a twin
axis, cumulative received batches (total and archive share), and, when the
loss channel was active, the Lost strip — to
`<run_dir>/plots/mission_summary_global.png` with a vector PDF twin. Must
run inside the telemetry theme. Returns the PNG path.
"""
function plot_mission_summary(ctx::PlotContext)
    df, df_x = ctx.df, ctx.df_x
    # Floor at one hour: a single-row (or sub-hour) profile would otherwise
    # produce degenerate axis limits and crash the renderer.
    max_x_h = max(df_x[end], 1.0)
    tick_vals_h = collect(0.0:summary_tick_step_hours(max_x_h/24.0):max_x_h)
    tick_labels = ["Day $(Int(floor(v/24)))" for v in tick_vals_h]

    fig = Figure(
        size = (
            PlotTheme.FIG_SIZE_SUMMARY[1],
            ctx.show_lost_panel ? PlotTheme.FIG_SIZE_SUMMARY[2] + 90 :
            PlotTheme.FIG_SIZE_SUMMARY[2],
        ),
        figure_padding = 10,
    )

    ax1 = Axis(
        fig[1, 1],
        xlabel = "",
        ylabel = "Bandwidth [%]",
        xticks = (tick_vals_h, tick_labels),
    )
    xlims!(ax1, 0, max_x_h)
    ylims!(ax1, 0, 105)

    ax1_twin = Axis(
        fig[1, 1],
        yaxisposition = :right,
        ylabel = "Buffered data batches",
        yticklabelcolor = PlotTheme.COLOR_ONBOARD,
    )
    hidespines!(ax1_twin)
    hidexdecorations!(ax1_twin)
    xlims!(ax1_twin, 0, max_x_h)
    ylims!(ax1_twin, 0, max(10.0, 1.3 * maximum(df.Onboard_Buffer)))

    shade_disruptions!(ax1, 0.0, max_x_h, ctx.disruption_spans)
    shade_outages!(ax1, 0.0, max_x_h, ctx.outage_spans)

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
            color = (PlotTheme.COLOR_BANDWIDTH, 0.35),
            linestyle = :dot,
        )
    end
    lines!(ax1, df_x, Float64.(df.Bandwidth_Pct), color = PlotTheme.COLOR_BANDWIDTH)
    lines!(
        ax1_twin,
        df_x,
        Float64.(df.Onboard_Buffer),
        color = PlotTheme.COLOR_ONBOARD,
        linestyle = :dash,
    )

    ax2 = Axis(
        fig[2, 1],
        xlabel = ctx.show_lost_panel ? "" : "Mission time",
        ylabel = "Received data batches",
        xticks = (tick_vals_h, tick_labels),
    )
    xlims!(ax2, 0, max_x_h)
    ylims!(ax2, 0, max(10.0, 1.2 * maximum(df.Ground_Total)))

    shade_disruptions!(ax2, 0.0, max_x_h, ctx.disruption_spans)
    shade_outages!(ax2, 0.0, max_x_h, ctx.outage_spans)

    band!(
        ax2,
        df_x,
        zeros(length(df_x)),
        Float64.(df.Ground_Total),
        color = (PlotTheme.COLOR_LIVE, 0.4),
    )
    stairs!(ax2, df_x, Float64.(df.Ground_Total), color = PlotTheme.COLOR_LIVE)
    band!(
        ax2,
        df_x,
        zeros(length(df_x)),
        Float64.(df.Ground_Arch),
        color = (PlotTheme.COLOR_ARCHIVE, 0.4),
    )
    stairs!(ax2, df_x, Float64.(df.Ground_Arch), color = PlotTheme.COLOR_ARCHIVE)

    # Dedicated Lost strip: rare discrete events get their own small linear
    # axis instead of an invisible flat line under the received bands.
    axes_to_link = [ax1, ax2]
    if ctx.show_lost_panel
        # LinearTicks(3): the strip is ~1/3 panel height, so the default
        # automatic ticks crowd together once losses reach double digits.
        ax3 = Axis(
            fig[3, 1],
            xlabel = "Mission time",
            ylabel = "Lost",
            xticks = (tick_vals_h, tick_labels),
            yticks = LinearTicks(3),
        )
        rowsize!(fig.layout, 3, Auto(0.32))
        xlims!(ax3, 0, max_x_h)
        lost_curve = ctx.has_loss_cols ? Float64.(df.Lost_Count) : zeros(length(df_x))
        ylims!(ax3, 0, max(4.0, 1.35 * maximum(lost_curve)))
        shade_disruptions!(ax3, 0.0, max_x_h, ctx.disruption_spans)
        shade_outages!(ax3, 0.0, max_x_h, ctx.outage_spans)
        stairs!(ax3, df_x, lost_curve, color = PlotTheme.COLOR_LOST)
        inc = [i for i in 2:length(lost_curve) if lost_curve[i] > lost_curve[i-1]]
        scatter!(
            ax3,
            df_x[inc],
            lost_curve[inc],
            marker = :xcross,
            color = PlotTheme.COLOR_LOST,
            markersize = PlotTheme.MARKERSIZE_DATA,
        )
        if lost_curve[end] > 0
            pct =
                100 * lost_curve[end] /
                max(1.0, Float64(df.Ground_Total[end]) + lost_curve[end])
            text!(
                ax3,
                0.985,
                0.88,
                text = "$(Int(lost_curve[end])) lost ($(round(pct, digits=2)) %)",
                space = :relative,
                align = (:right, :top),
                fontsize = PlotTheme.FONTSIZE_ANNOTATION,
                color = PlotTheme.COLOR_LOST,
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
        fig;
        degraded = show_nominal,
        blackout = spans_overlap(ctx.disruption_spans, 0.0, max_x_h, 1, 2),
        ramp = spans_overlap(ctx.disruption_spans, 0.0, max_x_h, 2, 3),
        outage = spans_overlap(ctx.outage_spans, 0.0, max_x_h, 1, 2),
        lost = ctx.show_lost_panel ? :strip : :none,
    )
    linkxaxes!(axes_to_link...)

    path = joinpath(ctx.run_dir, "plots", "mission_summary_global.png")
    save(path, fig, px_per_unit = 4)
    save(splitext(path)[1] * ".pdf", fig)
    return path
end

"""
    plot_session(ctx::PlotContext, day_k::Int) -> Union{Nothing,String}

Renders the session figure of mission day `day_k` (0-based) — the nominal
DSN window of that day: smooth nominal and effective capacity with the
onboard buffer on a twin axis, and the batches received within the window
(total and archive share) with ✕ pins and a count badge for any losses —
to `<run_dir>/plots/session_day<kk>_detail.png` with a vector PDF twin.
Returns `nothing` when the window lies outside the recorded span or holds
fewer than two metrics rows. Must run inside the telemetry theme.
"""
function plot_session(ctx::PlotContext, day_k::Int)
    df = ctx.df
    max_x_h = max(ctx.df_x[end], 1.0)
    min_sess_dt = DateTime(Date(ctx.t_start + Day(day_k)), ctx.session_start)
    max_sess_dt = min_sess_dt + ctx.session_duration
    min_sess_h = hours_since(min_sess_dt, ctx.t_start)
    max_sess_h = hours_since(max_sess_dt, ctx.t_start)
    # Windows entirely outside the recorded mission span produce nothing.
    (max_sess_h <= 0.0 || min_sess_h >= max_x_h) && return nothing

    in_window = (df.SimTime .>= min_sess_dt) .& (df.SimTime .<= max_sess_dt)
    session_df = df[in_window, :]
    length(session_df.SimTime) < 2 && return nothing

    t_smooth_dt = [
        min_sess_dt +
        Millisecond(round(Int, (j-1) * ctx.session_duration.value * 1000 / 199)) for
        j in 1:200
    ]
    t_smooth_h = [hours_since(t, ctx.t_start) for t in t_smooth_dt]
    bw_smooth = Float64[
        100.0 * ChannelEffects.effective_bandwidth(ctx.link_model, t) for t in t_smooth_dt
    ]
    bw_nominal_smooth = Float64[
        100.0 * TelemetryCore.get_bandwidth_factor(ctx.vis_model, t) for t in t_smooth_dt
    ]
    sess_degraded = maximum(abs.(bw_nominal_smooth .- bw_smooth)) > 0.1

    tick_start_dt = Dates.floor(min_sess_dt, Hour(1))
    session_tick_vals_dt = collect(tick_start_dt:Hour(1):max_sess_dt)
    session_tick_vals_h = [hours_since(t, ctx.t_start) for t in session_tick_vals_dt]
    session_tick_labels = [Dates.format(t, "HH:MM") for t in session_tick_vals_dt]

    session_hours = [hours_since(t, ctx.t_start) for t in session_df.SimTime]
    plot_x = Float64[min_sess_h; session_hours; max_sess_h]
    plot_gnd = Float64[
        0.0;
        session_df.Ground_Total .- session_df.Ground_Total[1];
        session_df.Ground_Total[end] - session_df.Ground_Total[1]
    ]
    plot_ground_archive = Float64[
        0.0;
        session_df.Ground_Arch .- session_df.Ground_Arch[1];
        session_df.Ground_Arch[end] - session_df.Ground_Arch[1]
    ]

    fig = Figure(size = PlotTheme.FIG_SIZE_SESSION, figure_padding = 10)

    ax_s1 = Axis(
        fig[1, 1],
        xlabel = "",
        ylabel = "Bandwidth [%]",
        xticks = (session_tick_vals_h, session_tick_labels),
    )
    xlims!(ax_s1, min_sess_h, max_sess_h)
    ylims!(ax_s1, 0, 105)

    ax_s1_twin = Axis(
        fig[1, 1],
        yaxisposition = :right,
        ylabel = "Buffered data batches",
        yticklabelcolor = PlotTheme.COLOR_ONBOARD,
    )
    hidespines!(ax_s1_twin)
    hidexdecorations!(ax_s1_twin)
    xlims!(ax_s1_twin, min_sess_h, max_sess_h)
    ylims!(ax_s1_twin, 0, max(10.0, 1.3 * maximum(session_df.Onboard_Buffer)))

    shade_disruptions!(ax_s1, min_sess_h, max_sess_h, ctx.disruption_spans)
    shade_outages!(ax_s1, min_sess_h, max_sess_h, ctx.outage_spans)
    if sess_degraded
        lines!(
            ax_s1,
            t_smooth_h,
            bw_nominal_smooth,
            color = (PlotTheme.COLOR_BANDWIDTH, 0.35),
            linestyle = :dot,
        )
    end
    lines!(ax_s1, t_smooth_h, bw_smooth, color = PlotTheme.COLOR_BANDWIDTH)
    lines!(
        ax_s1_twin,
        session_hours,
        Float64.(session_df.Onboard_Buffer),
        color = PlotTheme.COLOR_ONBOARD,
        linestyle = :dash,
    )

    ax_s2 = Axis(
        fig[2, 1],
        xlabel = "Mission time",
        ylabel = "Received data batches",
        xticks = (session_tick_vals_h, session_tick_labels),
        # HH:MM labels crowd at session resolution; rotation is applied
        # here rather than in the global theme (rule: rotate crowded labels
        # only).
        xticklabelrotation = π / 4,
    )
    xlims!(ax_s2, min_sess_h, max_sess_h)
    y_max_s2 = max(10.0, 1.2 * maximum(plot_gnd))
    ylims!(ax_s2, 0, y_max_s2)

    shade_disruptions!(ax_s2, min_sess_h, max_sess_h, ctx.disruption_spans)
    shade_outages!(ax_s2, min_sess_h, max_sess_h, ctx.outage_spans)

    band!(
        ax_s2,
        plot_x,
        zeros(length(plot_x)),
        plot_gnd,
        color = (PlotTheme.COLOR_LIVE, 0.4),
    )
    stairs!(ax_s2, plot_x, plot_gnd, color = PlotTheme.COLOR_LIVE)
    band!(
        ax_s2,
        plot_x,
        zeros(length(plot_x)),
        plot_ground_archive,
        color = (PlotTheme.COLOR_ARCHIVE, 0.4),
    )
    stairs!(ax_s2, plot_x, plot_ground_archive, color = PlotTheme.COLOR_ARCHIVE)

    # Session losses: no dedicated panel (it would sit empty on loss-free
    # days) — ✕ markers along the top edge at the loss instants plus a
    # corner count annotation, and no elements at all when the session lost
    # nothing.
    n_lost_sess =
        ctx.has_loss_cols ? Int(session_df.Lost_Count[end] - session_df.Lost_Count[1]) : 0
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
            color = PlotTheme.COLOR_LOST,
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
            color = PlotTheme.COLOR_LOST,
        )
    end

    hidexdecorations!(ax_s1, grid = false, ticks = false)
    foreach(ax -> ax.yticklabelspace = 34.0, (ax_s1, ax_s2))

    add_figure_legend!(
        fig;
        degraded = sess_degraded,
        blackout = spans_overlap(ctx.disruption_spans, min_sess_h, max_sess_h, 1, 2),
        ramp = spans_overlap(ctx.disruption_spans, min_sess_h, max_sess_h, 2, 3),
        outage = spans_overlap(ctx.outage_spans, min_sess_h, max_sess_h, 1, 2),
        lost = n_lost_sess > 0 ? :marks : :none,
    )
    linkxaxes!(ax_s1, ax_s2)

    path = joinpath(ctx.run_dir, "plots", "session_day$(lpad(day_k, 2, '0'))_detail.png")
    save(path, fig, px_per_unit = 4)
    save(splitext(path)[1] * ".pdf", fig)
    return path
end

"""
    generate_mission_plots(run_dir::String)

Reads `mission_profile.csv` and renders the mission summary
([`plot_mission_summary`](@ref)) and one session figure per mission day
([`plot_session`](@ref)) into `<run_dir>/plots`, all under the telemetry
theme. Sessions are enumerated from the nominal daily DSN window — not
detected from the effective bandwidth — so a fully blacked-out day still
receives its zero-throughput figure and file names share the summary's
0-based day coordinates.
"""
function generate_mission_plots(run_dir::String)
    @info "[RECEIVER] Generating mission and session plots..."

    log_path = joinpath(run_dir, "mission_profile.csv")
    if !isfile(log_path)
        @warn "[POST] mission_profile.csv missing in $run_dir — the receiver produced no metrics (component never ran?); skipping this product."
        return
    end
    df = TelemetryCore.normalize_profile!(CSV.read(log_path, DataFrame))
    isempty(df) && return

    ctx = plot_context(run_dir, df, TelemetryCore.load_run_config(run_dir))
    with_theme(PlotTheme.telemetry_theme()) do
        global_path = plot_mission_summary(ctx)
        @info "[RECEIVER] Saved Global Summary Plot: $(relpath(global_path, run_dir))"
        n_days = ceil(Int, max(ctx.df_x[end], 1.0) / 24.0)
        for day_k in 0:(n_days-1)
            plot_session(ctx, day_k)
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
    (
        :onboard_live,
        :onboard_archive,
        :link_live,
        :link_archive,
        :ground_live,
        :ground_archive,
        :lost,
    ),
    NTuple{7,Vector{Int}},
}

"""
    reconstruct_batch_states(run_dir::String, df::DataFrame)

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
function reconstruct_batch_states(run_dir::String, df::DataFrame)
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
        :onboard_live => Int[],
        :onboard_archive => Int[],
        :link_live => Int[],
        :link_archive => Int[],
        :ground_live => Int[],
        :ground_archive => Int[],
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
        :onboard_live => 1,
        :onboard_archive => 1,
        :link_live => 2,
        :link_archive => 2,
        :ground_live => 3,
        :ground_archive => 3,
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
                place!(id, is_live ? :onboard_live : :onboard_archive)
            elseif kind == "tx"
                place!(id, is_live ? :link_live : :link_archive)
            elseif kind == "ingested"
                place!(id, is_live ? :ground_live : :ground_archive)
            elseif kind == "lost"
                place!(id, :lost)
            end
            ev_idx += 1
        end
        push!(
            states,
            (
                onboard_live = copy(category[:onboard_live]),
                onboard_archive = copy(category[:onboard_archive]),
                link_live = copy(category[:link_live]),
                link_archive = copy(category[:link_archive]),
                ground_live = copy(category[:ground_live]),
                ground_archive = copy(category[:ground_archive]),
                lost = copy(category[:lost]),
            ),
        )
    end
    return states
end

"""
    batch_states(run_dir::String, df::DataFrame) -> Vector{BatchStates}

Batch-location history of a run: the exact event-log replay
([`reconstruct_batch_states`](@ref)) over the metrics frame `df`. Runs
without `events_tx.csv` (pre-0.9 layouts) are not supported and raise an
error.
"""
function batch_states(run_dir::String, df::DataFrame)
    isfile(joinpath(run_dir, "events_tx.csv")) || error(
        "[POST] events_tx.csv missing in $run_dir — the batch-state replay needs the ground-truth event log; runs without it are not supported.",
    )
    return reconstruct_batch_states(run_dir, df)
end

"""
    generate_telemetry_masks(run_dir::String)

A post-processing utility that reconstructs the LIFO/FIFO transmission state
machine from the event logs (see [`batch_states`](@ref)). It outputs a 2D matrix `telemetry_mask_timeline.csv`
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

    df = TelemetryCore.normalize_profile!(CSV.read(log_path, DataFrame))
    if isempty(df)
        return
    end

    states = batch_states(run_dir, df)
    # True maximum batch ID, not the batch count: the ID space may carry
    # holes (truncated logs, hand-assembled or reconciled run directories),
    # and a count-sized matrix would fault on the first such hole.
    max_id_ever =
        isempty(states) ? 0 : maximum(cat -> isempty(cat) ? 0 : maximum(cat), last(states))

    # 0 = Future, 1 = Onboard, 2 = Link, 3 = Ground, 4 = Lost
    mask_matrix = zeros(Int8, nrow(df), max_id_ever)

    for (i, st) in enumerate(states),
        (code, cats) in (
            (Int8(1), (st.onboard_live, st.onboard_archive)),
            (Int8(2), (st.link_live, st.link_archive)),
            (Int8(3), (st.ground_live, st.ground_archive)),
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
    expand_pointwise_mask(run_dir, total_points, event_idx, output_path) -> Int

Expands one row of `masks/telemetry_mask_timeline.csv` (`event_idx`; `-1`
selects the final snapshot) into a point-wise 0/1 availability array of
`total_points` samples — 1 where the owning batch is on the ground
(state 3); states 0 (future), 1 (onboard), 2 (link), and 4 (lost) stay 0, a
lost batch never becoming available — and writes it as
`Time_Index, Ground_Available` to `output_path` (with `safe_csv_write`
rotation). Points per batch follow the run's own configuration snapshot.
Returns the number of available points.
"""
function expand_pointwise_mask(
    run_dir::String,
    total_points::Int,
    event_idx::Int,
    output_path::String,
)
    mask_path = joinpath(run_dir, "masks", "telemetry_mask_timeline.csv")
    isfile(mask_path) || error("[POST] Telemetry mask not found at: $mask_path")
    physics = TelemetryCore.physics_settings(TelemetryCore.load_run_config(run_dir))
    points_per_batch =
        round(Int, physics.sample_rate * physics.segment_duration_sec * physics.batch_size)
    mask_df = CSV.read(mask_path, DataFrame)
    target_idx = event_idx == -1 ? nrow(mask_df) : event_idx
    1 <= target_idx <= nrow(mask_df) || error(
        "[POST] Event index $target_idx is out of bounds: the timeline has $(nrow(mask_df)) events.",
    )
    event_row = mask_df[target_idx, :]
    @info "[POST] Expanding mask row $target_idx ($(event_row.SimTime)) to $total_points points ($points_per_batch per batch)."
    point_mask = zeros(Int8, total_points)
    for (batch_index, status) in enumerate(Vector(event_row[2:end]))
        status == 3 || continue
        start_idx = (batch_index - 1) * points_per_batch + 1
        start_idx <= total_points || continue
        point_mask[start_idx:min(start_idx+points_per_batch-1, total_points)] .= 1
    end
    TelemetryCore.safe_csv_write(
        output_path,
        DataFrame(Time_Index = 1:total_points, Ground_Available = point_mask),
    )
    available = count(==(1), point_mask)
    @info "[POST] Point-wise mask saved to $output_path: $available of $total_points points available on the ground ($(round(100 * available / total_points, digits = 2)) %)."
    return available
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
    # logging (they remain on the link in the mask replay).
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
