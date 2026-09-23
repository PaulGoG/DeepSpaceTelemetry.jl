"""
    MissionFigures

The figure products of a run: the mission summary, the per-contact session
figures, and the batch-state raster, composed at the standard layout of
[`PlotTheme`](@ref) from the metrics profile, the event logs, and the
batch-state timeline of the run directory.
"""
module MissionFigures

using ..TelemetryCore
using ..ChannelEffects
using ..PlotTheme
using CSV: CSV
using CairoMakie:
    Axis,
    Figure,
    LineElement,
    MarkerElement,
    PolyElement,
    band!,
    cgrad,
    heatmap!,
    hidespines!,
    hidexdecorations!,
    lines!,
    linkxaxes!,
    scatter!,
    stairs!,
    text!,
    translate!,
    hlines!,
    vlines!,
    vspan!,
    with_theme,
    xlims!,
    ylims!
using DataFrames: DataFrames, DataFrame, names, nrow
using Dates: Dates, DateTime, Hour, Millisecond, Second

"""
    hours_since(t::DateTime, t0::DateTime) -> Float64

Elapsed mission hours from `t0` to `t` — the plot-coordinate transform of
every figure (time axes are anchored at `start_sim_time`, 0-based days).
"""
hours_since(t::DateTime, t0::DateTime) = Float64((t - t0).value) / TelemetryCore.MS_PER_HOUR

"""
    PlotContext

Per-run inputs shared by the mission summary and the session figures: the
metrics frame with its elapsed-hour axis, the mission epoch, the
visibility and link models, the disruption, component-outage,
low-latency and event-marker spans in plot coordinates, and the loss-panel
policy. Built once by [`plot_context`](@ref).
"""
struct PlotContext
    run_dir::String
    df::DataFrame
    df_x::Vector{Float64}
    t_start::DateTime
    vis_model::TelemetryCore.VisibilityModel
    link_model::ChannelEffects.LinkModel
    disruption_spans::Vector{NTuple{3,Float64}} # (blackout start, blackout end, recovery end)
    outage_spans::Vector{NTuple{2,Float64}}     # component down → restart (or mission end)
    scheduled_gap_spans::Vector{NTuple{2,Float64}} # SCHEDULED gap_start → gap_end
    recorder_spans::Vector{NTuple{2,Float64}}   # RECORDER gap_start → gap_end (or mission end)
    recorder_capacity::Float64                  # batches; NaN when never reached
    low_latency_spans::Vector{NTuple{2,Float64}} # low-latency periods, scheduled and triggered
    marker_times::Vector{Float64}               # declared event markers [h since t_start]
    has_loss_cols::Bool
    show_lost_panel::Bool
end

"""
    SPAN_COALESCE_FRACTION

Fraction of the plotted time range below which two recorder-full spans are
drawn as one band ([`coalesce_spans`](@ref)).
"""
const SPAN_COALESCE_FRACTION = 0.005

"""
    coalesce_spans(spans, min_gap::Real) -> Vector{NTuple{2,Float64}}

`spans` (`(start, stop)` pairs in hours, any order) sorted by start and
merged wherever the interval from one span's stop to the next span's start
is below `min_gap`. A recorder toggling at capacity on a weak link opens a
gap per transmitted batch; at mission scale the boundary lines of those
gaps would tile the panel.
"""
function coalesce_spans(spans, min_gap::Real)
    merged = NTuple{2,Float64}[]
    for (a, b) in sort(collect(NTuple{2,Float64}, spans); by = first)
        if !isempty(merged) && a - merged[end][2] < min_gap
            merged[end] = (merged[end][1], max(merged[end][2], b))
        else
            push!(merged, (a, b))
        end
    end
    return merged
end

"""
    generation_gap_spans(run_dir, t_start, x_end, tag) -> Vector{NTuple{2,Float64}}

Generation-gap windows from the emitter's `events_tx.csv`: `gap_start` /
`gap_end` pairs whose `Batch` column equals `tag` (`SCHEDULED` for planned
gaps, `RECORDER` for recorder overflows, `STREAM` for outages recorded by
the supervisor), in hours since `t_start`; an unclosed gap ends at `x_end`.
"""
function generation_gap_spans(
    run_dir::String,
    t_start::DateTime,
    x_end::Float64,
    tag::String,
)
    spans = NTuple{2,Float64}[]
    path = joinpath(run_dir, "events_tx.csv")
    isfile(path) || return spans
    events = CSV.read(path, DataFrame)
    isempty(events) && return spans
    open_start = nothing
    for r in eachrow(events)
        String(r.Batch) == tag || continue
        if r.Event == "gap_start"
            open_start = DateTime(r.SimTime)
        elseif r.Event == "gap_end" && open_start !== nothing
            push!(
                spans,
                (
                    hours_since(open_start, t_start),
                    hours_since(DateTime(r.SimTime), t_start),
                ),
            )
            open_start = nothing
        end
    end
    open_start === nothing || push!(spans, (hours_since(open_start, t_start), x_end))
    return spans
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
    vis_model = TelemetryCore.visibility_model(cfg)
    sim = get(cfg, "simulation", Dict{String,Any}())
    disruptions = try
        haskey(sim, "start_sim_time") ?
        ChannelEffects.build_disruption_timeline(cfg, DateTime(sim["start_sim_time"])) :
        ChannelEffects.DisruptionTimeline()
    catch e
        @warn "[POST] Could not parse disruption events from the run snapshot; plotting without disruption shading." exception =
            e
        ChannelEffects.DisruptionTimeline()
    end
    start_text = string(get(sim, "start_sim_time", ""))
    sim_start = tryparse(DateTime, start_text)
    sim_start === nothing &&
        @warn "[POST] start_sim_time \"$start_text\" of the run snapshot is not an ISO-8601 datetime; anchoring the time axis at the first metrics row."
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
    recorder_spans = generation_gap_spans(run_dir, t_start, maximum(df_x), "RECORDER")
    recorder_capacity =
        isempty(recorder_spans) ? NaN :
        try
            Float64(TelemetryCore.onboard_capacity(cfg).batches)
        catch e
            @warn "[POST] Could not derive the recorder capacity from the run snapshot." exception =
                e
            NaN
        end
    return PlotContext(
        run_dir,
        df,
        df_x,
        t_start,
        vis_model,
        ChannelEffects.LinkModel(vis_model, disruptions),
        disruption_spans,
        component_outage_spans(run_dir, t_start, maximum(df_x)),
        generation_gap_spans(run_dir, t_start, maximum(df_x), "SCHEDULED"),
        recorder_spans,
        recorder_capacity,
        low_latency_spans(vis_model, t_start, maximum(df_x)),
        marker_times(run_dir, t_start),
        has_loss_cols,
        (loss_enabled && has_loss_cols) || any_lost,
    )
end

"""
    low_latency_spans(model::TelemetryCore.VisibilityModel, t_start, x_end) -> Vector{NTuple{2,Float64}}

Low-latency periods of the run — scheduled ones and those triggered by an
event marker — as `(start, stop)` pairs in hours since `t_start`, clipped to
`[0, x_end]`. Empty when `contacts.low_latency_enabled` is unset, the
[`TelemetryCore.VisibilityModel`](@ref) then carrying no such window.
"""
function low_latency_spans(
    model::TelemetryCore.VisibilityModel,
    t_start::DateTime,
    x_end::Float64,
)
    t_end = t_start + Second(round(Int, 3600 * max(x_end, 0.0)))
    return [
        (hours_since(w.start, t_start), hours_since(w.stop, t_start)) for
        w in TelemetryCore.contact_windows(model, t_start, t_end) if w.low_latency
    ]
end

"""
    marker_times(run_dir::String, t_start::DateTime) -> Vector{Float64}

Declared event markers of the run, in hours since `t_start`, read from the
run's own `markers.csv` ([`TelemetryCore.load_markers`](@ref)). Empty when
the run declared none or predates the marker record — the figures then draw
no marker rules.
"""
function marker_times(run_dir::String, t_start::DateTime)
    return [hours_since(m.time, t_start) for m in TelemetryCore.load_markers(run_dir)]
end

"""
    mark_events!(ax, x_lo, x_hi, times; style)

Draws one upright rule per declared event marker onto `ax`, clamped to the
plotted range, in [`PlotTheme.COLOR_MARKER`](@ref) at the guide line width of
`style` and behind the data. The rule is solid, the one vertical style no
shaded window uses for its edges, so a marker never reads as an event
boundary. The markers are the instants at which the alert-latency metric is
evaluated, and the origin of any triggered low-latency period.
"""
function mark_events!(
    ax,
    x_lo::Float64,
    x_hi::Float64,
    times;
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
)
    for x_marker in times
        x_lo <= x_marker <= x_hi || continue
        l = vlines!(
            ax,
            [x_marker],
            color = (PlotTheme.COLOR_MARKER, 0.6),
            linewidth = style.linewidth_guide,
        )
        translate!(l, 0, 0, -97)
    end
    return ax
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
    shade_spans!(ax, x_lo, x_hi, spans; color, edgecolor, linestyle, style)

Shades `(start, stop)` spans onto `ax`, clamped to the plotted range: a wash
of `color` with same-hue edge lines (`edgecolor`, `linestyle`) at the guide
line width of `style`, pushed behind the data. The defaults are the
component-outage styling ([`PlotTheme.COLOR_OUTAGE`](@ref), dotted edges);
the generation-gap, recorder-full, and low-latency washes pass their own.
"""
function shade_spans!(
    ax,
    x_lo::Float64,
    x_hi::Float64,
    spans;
    color = (PlotTheme.COLOR_OUTAGE, 0.10),
    edgecolor = (PlotTheme.COLOR_OUTAGE, 0.5),
    linestyle = :dot,
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
)
    for (o0, o1) in spans
        o0c, o1c = max(o0, x_lo), min(o1, x_hi)
        o0c < o1c || continue
        v = vspan!(ax, o0c, o1c, color = color)
        translate!(v, 0, 0, -99)
        for x_edge in (o0, o1)
            if x_lo <= x_edge <= x_hi
                l = vlines!(
                    ax,
                    [x_edge],
                    color = edgecolor,
                    linestyle = linestyle,
                    linewidth = style.linewidth_guide,
                )
                translate!(l, 0, 0, -98)
            end
        end
    end
    return ax
end

"""
    shade_generation_gaps!(ax, x_lo, x_hi, ctx::PlotContext; style)

Scheduled generation gaps (onboard-family color, dash-dot edges) and
recorder overflows (loss color, dash-dot edges) behind the data of `ax`,
edge lines at the guide line width of `style`. Recorder overflows closer
than [`SPAN_COALESCE_FRACTION`](@ref) of the plotted range are drawn as one
band ([`coalesce_spans`](@ref)).
"""
function shade_generation_gaps!(
    ax,
    x_lo::Float64,
    x_hi::Float64,
    ctx::PlotContext;
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
)
    shade_spans!(
        ax,
        x_lo,
        x_hi,
        ctx.scheduled_gap_spans;
        color = (PlotTheme.COLOR_ONBOARD, 0.25),
        edgecolor = (PlotTheme.COLOR_ONBOARD, 0.9),
        linestyle = :dashdot,
        style = style,
    )
    shade_spans!(
        ax,
        x_lo,
        x_hi,
        coalesce_spans(ctx.recorder_spans, SPAN_COALESCE_FRACTION * (x_hi - x_lo));
        color = (PlotTheme.COLOR_LOST, 0.12),
        edgecolor = (PlotTheme.COLOR_LOST, 0.9),
        linestyle = :dashdot,
        style = style,
    )
    return ax
end

"""
    shade_low_latency!(ax, x_lo, x_hi, ctx::PlotContext; style)

Low-latency periods behind the data of `ax`, in the capacity color at low
alpha with dash-dot-dot same-hue edges, distinct from the dotted
nominal-capacity curve — the periods run at `low_latency_capacity_fraction`
of peak capacity, so the wash sits under the capacity curve it explains.
"""
function shade_low_latency!(
    ax,
    x_lo::Float64,
    x_hi::Float64,
    ctx::PlotContext;
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
)
    shade_spans!(
        ax,
        x_lo,
        x_hi,
        ctx.low_latency_spans;
        color = (PlotTheme.COLOR_BANDWIDTH, 0.12),
        edgecolor = (PlotTheme.COLOR_BANDWIDTH, 0.7),
        linestyle = :dashdotdot,
        style = style,
    )
    return ax
end

"""
    shade_disruptions!(ax, x_lo, x_hi, disruption_spans; style)

Shades every disruption event onto `ax`, clamped to the plotted range: a
uniform wash over the blackout, fading linearly to zero alpha across the
recovery ramp (mirroring the capacity ramp), with dashed same-hue lines at
the guide line width of `style` delimiting event start and full recovery.
All shading is pushed far back along z so it renders behind the data
identically on every panel — but strictly above z = -100, where the white
background of a twin axis (dual-y panels) would cover it.
"""
function shade_disruptions!(
    ax,
    x_lo::Float64,
    x_hi::Float64,
    disruption_spans;
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
)
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
                    color = (PlotTheme.COLOR_DISRUPTION, 0.55),
                    linestyle = :dash,
                    linewidth = style.linewidth_guide,
                )
                translate!(l, 0, 0, -98)
            end
        end
    end
    return ax
end

"""
    figure_legend_entries(; degraded, blackout, ramp, lost, outage = false, …) -> Vector{Tuple{String,Vector{Any},Vector{String}}}

Legend elements and labels of a figure, with composite fill+edge patches for
the band+stair pairs. Entries are strictly limited to what that figure
draws: `degraded` swaps the single capacity entry for the nominal/effective
pair, `blackout`/`ramp`/`outage`/`scheduled_gap`/`recorder`/`low_latency`
gate the shading patches, `marker` gates the event-marker rule, and `lost` is
`:strip` (summary stairs + marks), `:marks` (session ✕ pins), or `:none`.
The entries come in three families — `Link`, `Received`, `Events` — each a
`(title, elements, labels)` tuple for [`PlotTheme.figure_legend!`](@ref);
under its header a label names the series only (`Total (live + archive)`, not
`Total received …`).
"""
function figure_legend_entries(;
    degraded::Bool,
    blackout::Bool,
    ramp::Bool,
    lost::Symbol,
    outage::Bool = false,
    scheduled_gap::Bool = false,
    recorder::Bool = false,
    low_latency::Bool = false,
    marker::Bool = false,
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
)
    link_elems = Any[]
    link_labels = String[]
    received_elems = Any[]
    received_labels = String[]
    event_elems = Any[]
    event_labels = String[]
    if degraded
        push!(
            link_elems,
            LineElement(
                color = (PlotTheme.COLOR_BANDWIDTH, 0.5),
                linewidth = style.linewidth,
                linestyle = :dot,
            ),
        )
        push!(link_labels, "Nominal capacity")
        push!(
            link_elems,
            LineElement(color = PlotTheme.COLOR_BANDWIDTH, linewidth = style.linewidth),
        )
        push!(link_labels, "Effective capacity")
    else
        push!(
            link_elems,
            LineElement(color = PlotTheme.COLOR_BANDWIDTH, linewidth = style.linewidth),
        )
        push!(link_labels, "Link capacity")
    end
    push!(
        link_elems,
        LineElement(
            color = PlotTheme.COLOR_ONBOARD,
            linewidth = style.linewidth,
            linestyle = :dash,
        ),
    )
    push!(link_labels, "Onboard buffer")
    if recorder
        push!(
            link_elems,
            LineElement(
                color = PlotTheme.COLOR_ONBOARD,
                linewidth = style.linewidth_guide,
                linestyle = :dot,
            ),
        )
        push!(link_labels, "Recorder capacity")
    end
    push!(
        received_elems,
        PolyElement(
            color = (PlotTheme.COLOR_LIVE, PlotTheme.FILL_ALPHA),
            strokecolor = PlotTheme.COLOR_LIVE,
            strokewidth = style.linewidth_edge,
        ),
    )
    push!(received_labels, "Total (live + archive)")
    push!(
        received_elems,
        PolyElement(
            color = (PlotTheme.COLOR_ARCHIVE, PlotTheme.FILL_ALPHA),
            strokecolor = PlotTheme.COLOR_ARCHIVE,
            strokewidth = style.linewidth_edge,
        ),
    )
    push!(received_labels, "Archive (LIFO)")
    if lost === :strip
        push!(
            received_elems,
            [
                LineElement(color = PlotTheme.COLOR_LOST, linewidth = style.linewidth),
                MarkerElement(
                    marker = :xcross,
                    color = PlotTheme.COLOR_LOST,
                    markersize = style.markersize,
                ),
            ],
        )
        push!(received_labels, "Lost")
    elseif lost === :marks
        push!(
            received_elems,
            MarkerElement(
                marker = :xcross,
                color = PlotTheme.COLOR_LOST,
                markersize = style.markersize,
            ),
        )
        push!(received_labels, "Lost")
    end
    # Shaded windows: fill patch plus the line style of the window's edge
    # lines, so blackout, ramp, and outage stay apart in grayscale.
    if blackout
        push!(
            event_elems,
            shading_patch(
                (PlotTheme.COLOR_DISRUPTION, 0.18),
                (PlotTheme.COLOR_DISRUPTION, 0.55),
                :dash,
                style,
            ),
        )
        push!(event_labels, "Blackout")
    end
    if ramp
        push!(
            event_elems,
            shading_patch(
                (PlotTheme.COLOR_DISRUPTION, 0.08),
                (PlotTheme.COLOR_DISRUPTION, 0.55),
                :dash,
                style,
            ),
        )
        push!(event_labels, "Recovery ramp")
    end
    if outage
        push!(
            event_elems,
            shading_patch(
                (PlotTheme.COLOR_OUTAGE, 0.10),
                (PlotTheme.COLOR_OUTAGE, 0.5),
                :dot,
                style,
            ),
        )
        push!(event_labels, "Component outage")
    end
    if scheduled_gap
        push!(
            event_elems,
            shading_patch(
                (PlotTheme.COLOR_ONBOARD, 0.25),
                (PlotTheme.COLOR_ONBOARD, 0.9),
                :dashdot,
                style,
            ),
        )
        push!(event_labels, "Generation gap")
    end
    if recorder
        push!(
            event_elems,
            shading_patch(
                (PlotTheme.COLOR_LOST, 0.12),
                (PlotTheme.COLOR_LOST, 0.9),
                :dashdot,
                style,
            ),
        )
        push!(event_labels, "Recorder full")
    end
    if low_latency
        push!(
            event_elems,
            shading_patch(
                (PlotTheme.COLOR_BANDWIDTH, 0.12),
                (PlotTheme.COLOR_BANDWIDTH, 0.7),
                :dashdotdot,
                style,
            ),
        )
        push!(event_labels, "Low-latency period")
    end
    if marker
        push!(
            event_elems,
            LineElement(
                color = (PlotTheme.COLOR_MARKER, 0.6),
                linewidth = style.linewidth_guide,
            ),
        )
        push!(event_labels, "Event marker")
    end
    return [
        ("Link", link_elems, link_labels),
        ("Received", received_elems, received_labels),
        ("Events", event_elems, event_labels),
    ]
end

"""
    add_figure_legend!(fig; degraded, blackout, ramp, lost, outage = false, …) -> fig

One frameless horizontal legend strip above the panels of `fig`, carrying the
entry families [`figure_legend_entries`](@ref) builds from the same keywords,
placed and fitted to the figure width by [`PlotTheme.figure_legend!`](@ref).
"""
function add_figure_legend!(
    fig;
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
    kwargs...,
)
    PlotTheme.figure_legend!(fig, style, figure_legend_entries(; style = style, kwargs...))
    return fig
end

"""
    shading_patch(fill, edge, linestyle::Symbol, style::PlotTheme.PlotStyle) -> Vector

Legend entry of a shaded event window: the fill patch under a line in the
color and line style of the window's edge lines, at the guide line width
of `style`.
"""
shading_patch(fill, edge, linestyle::Symbol, style::PlotTheme.PlotStyle) = [
    PolyElement(color = fill),
    LineElement(color = edge, linestyle = linestyle, linewidth = style.linewidth_guide),
]

"""
    upright_rules(ctx::PlotContext) -> Vector{Float64}

Every x position at which a figure of `ctx` draws an upright rule: the
boundaries of the disruption, outage, generation-gap and low-latency
windows, and the event markers. In-axis annotations pick their end of the
axis against this list ([`PlotTheme.annotation_side`](@ref)), so a rule never
crosses a text block.
"""
function upright_rules(ctx::PlotContext)
    xs = Float64[]
    for s in ctx.disruption_spans
        append!(xs, (s[1], s[3]))
    end
    for spans in (
        ctx.outage_spans,
        ctx.scheduled_gap_spans,
        ctx.recorder_spans,
        ctx.low_latency_spans,
    )
        for s in spans
            append!(xs, (s[1], s[2]))
        end
    end
    append!(xs, ctx.marker_times)
    return xs
end

"""
    TICK_LABEL_SPACE

Width reserved for the y tick labels of every stacked panel at the standard
layout, in Makie units (four digits at the tick size): with equal
reservations the y-labels of stacked panels form one aligned column.
"""
const TICK_LABEL_SPACE = 70

"""
    summary_tick_step_hours(total_days) -> Float64

Day-tick spacing of the mission summary [h]: the smallest step of 1, 2, 5,
10, 20, 30, or 60 days that places at most eleven `Day n` labels on the
axis (the labels touch beyond that at the design width), 120 days beyond.
"""
function summary_tick_step_hours(total_days::Float64)
    for step in (1, 2, 5, 10, 20, 30, 60)
        total_days / step <= 10 && return 24.0 * step
    end
    return 24.0 * 120
end

"""
    mission_time_ticks(span_hours::Float64) -> (values, labels, axis_label)

Tick positions [h], tick labels, and axis label of a mission-time axis
spanning `span_hours`: `Day n` labels at the spacing of
[`summary_tick_step_hours`](@ref) from two days on; below that, where a
day axis would carry one or two labels, whole hours at a step of 6 h (3 h
up to one day, 1 h up to 8 h) with the unit in the axis label.
"""
function mission_time_ticks(span_hours::Float64)
    if span_hours >= 48.0
        values = collect(0.0:summary_tick_step_hours(span_hours/24.0):span_hours)
        return values, ["Day $(Int(floor(v / 24)))" for v in values], "Mission time"
    end
    step = span_hours > 24.0 ? 6.0 : span_hours > 8.0 ? 3.0 : 1.0
    values = collect(0.0:step:span_hours)
    return values, [string(Int(v)) for v in values], "Mission time [h]"
end

"""
    count_tick_step(y_top::Real) -> Int

Tick step of a batch-count axis reaching `y_top`: the smallest of 1, 2 and 5
times a power of ten that fits at most three steps below `y_top`, so the
labels read as counts (0, 50, 100 rather than 0, 36, 72).
"""
function count_tick_step(y_top::Real)
    for k in 0:12, m in (1, 2, 5)
        step = m * 10^k
        y_top / step <= 3 && return step
    end
    return 5 * 10^12
end

"""
    SESSION_PIN_HEIGHT

Relative height of the lost-batch pins on the received panel of the session
figure: below the top row, which the loss count and the low-latency note
occupy, and above the data, whose maximum sits at 1/1.2 of the axis.
"""
const SESSION_PIN_HEIGHT = 0.88

"""
    plot_mission_summary(ctx::PlotContext) -> String

Renders the mission summary — capacity with the onboard buffer on a twin
axis, cumulative received batches (total and archive share), and, when the
loss channel was active, the Lost strip — to
`<run_dir>/plots/mission_summary_global.png` with a vector PDF twin. Must
run inside the telemetry theme. Returns the PNG path.
"""
function plot_mission_summary(
    ctx::PlotContext;
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
    plots_dir::String = joinpath(ctx.run_dir, "plots"),
    formats = ("png", "pdf"),
    suffix::String = "",
)
    df, df_x = ctx.df, ctx.df_x
    # Floor at one hour: a single-row (or sub-hour) profile would otherwise
    # produce degenerate axis limits and crash the renderer.
    max_x_h = max(df_x[end], 1.0)
    tick_vals_h, tick_labels, time_label = mission_time_ticks(max_x_h)

    # Nominal (visibility-only) capacity is drawn behind the effective curve
    # when a disruption degraded the link somewhere in the run; the legend
    # needs to know before it is built.
    show_nominal =
        hasproperty(df, :Nominal_Bandwidth_Pct) &&
        maximum(abs.(df.Nominal_Bandwidth_Pct .- df.Bandwidth_Pct)) > 0.1
    legend_flags = (
        degraded = show_nominal,
        blackout = spans_overlap(ctx.disruption_spans, 0.0, max_x_h, 1, 2),
        ramp = spans_overlap(ctx.disruption_spans, 0.0, max_x_h, 2, 3),
        outage = spans_overlap(ctx.outage_spans, 0.0, max_x_h, 1, 2),
        scheduled_gap = spans_overlap(ctx.scheduled_gap_spans, 0.0, max_x_h, 1, 2),
        recorder = spans_overlap(ctx.recorder_spans, 0.0, max_x_h, 1, 2),
        low_latency = spans_overlap(ctx.low_latency_spans, 0.0, max_x_h, 1, 2),
        marker = any(x -> 0.0 <= x <= max_x_h, ctx.marker_times),
        lost = ctx.show_lost_panel ? :strip : :none,
    )

    # Provisional height: size_to_panels! sets it once the layout is complete.
    fig = Figure(size = (style.width, style.width))

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

    shade_disruptions!(ax1, 0.0, max_x_h, ctx.disruption_spans; style)
    shade_spans!(ax1, 0.0, max_x_h, ctx.outage_spans; style)
    shade_generation_gaps!(ax1, 0.0, max_x_h, ctx; style)
    shade_low_latency!(ax1, 0.0, max_x_h, ctx; style)
    mark_events!(ax1, 0.0, max_x_h, ctx.marker_times; style)
    if !isnan(ctx.recorder_capacity)
        hlines!(
            ax1_twin,
            [ctx.recorder_capacity],
            color = PlotTheme.COLOR_ONBOARD,
            linestyle = :dot,
            linewidth = style.linewidth_guide,
        )
    end

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
        xlabel = ctx.show_lost_panel ? "" : time_label,
        ylabel = "Received data batches",
        xticks = (tick_vals_h, tick_labels),
        yticks = PlotTheme.UpperPrunedTicks(),
    )
    xlims!(ax2, 0, max_x_h)
    ylims!(ax2, 0, max(10.0, 1.2 * maximum(df.Ground_Total)))

    shade_disruptions!(ax2, 0.0, max_x_h, ctx.disruption_spans; style)
    shade_spans!(ax2, 0.0, max_x_h, ctx.outage_spans; style)
    shade_generation_gaps!(ax2, 0.0, max_x_h, ctx; style)
    shade_low_latency!(ax2, 0.0, max_x_h, ctx; style)
    mark_events!(ax2, 0.0, max_x_h, ctx.marker_times; style)

    band!(
        ax2,
        df_x,
        zeros(length(df_x)),
        Float64.(df.Ground_Total),
        color = (PlotTheme.COLOR_LIVE, PlotTheme.FILL_ALPHA),
    )
    stairs!(
        ax2,
        df_x,
        Float64.(df.Ground_Total),
        color = PlotTheme.COLOR_LIVE,
        linewidth = style.linewidth_edge,
    )
    band!(
        ax2,
        df_x,
        zeros(length(df_x)),
        Float64.(df.Ground_Arch),
        color = (PlotTheme.COLOR_ARCHIVE, PlotTheme.FILL_ALPHA),
    )
    stairs!(
        ax2,
        df_x,
        Float64.(df.Ground_Arch),
        color = PlotTheme.COLOR_ARCHIVE,
        linewidth = style.linewidth_edge,
    )

    # Dedicated Lost strip: rare discrete events get their own small linear
    # axis instead of an invisible flat line under the received bands.
    axes_to_link = [ax1, ax2]
    if ctx.show_lost_panel
        lost_curve = ctx.has_loss_cols ? Float64.(df.Lost_Count) : zeros(length(df_x))
        # Batches are counted, so the strip carries integer ticks at a 1–2–5
        # step that keeps at most three steps on the short strip; a lossless
        # run still gets the full 0…4 frame.
        y_top = max(4.0, 1.35 * maximum(lost_curve))
        tick_step = count_tick_step(y_top)
        ax3 = Axis(
            fig[3, 1],
            xlabel = time_label,
            ylabel = "Lost batches",
            xticks = (tick_vals_h, tick_labels),
            yticks = 0:tick_step:floor(Int, y_top),
        )
        xlims!(ax3, 0, max_x_h)
        # A lossless run draws a flat zero stair, which would otherwise
        # coincide with the axis frame and read as an unplotted panel.
        # Headroom above the top tick: a label on the frame would meet the
        # `0` of the panel above.
        ylims!(ax3, -0.06 * y_top, 1.15 * y_top)
        shade_disruptions!(ax3, 0.0, max_x_h, ctx.disruption_spans; style)
        shade_spans!(ax3, 0.0, max_x_h, ctx.outage_spans; style)
        shade_low_latency!(ax3, 0.0, max_x_h, ctx; style)
        mark_events!(ax3, 0.0, max_x_h, ctx.marker_times; style)
        stairs!(ax3, df_x, lost_curve, color = PlotTheme.COLOR_LOST)
        inc = [i for i in 2:length(lost_curve) if lost_curve[i] > lost_curve[i-1]]
        scatter!(
            ax3,
            df_x[inc],
            lost_curve[inc],
            marker = :xcross,
            color = PlotTheme.COLOR_LOST,
            markersize = style.markersize,
        )
        # The strip states its takeaway in either direction: a lossless run
        # reads "0 lost (0 %)" instead of presenting an empty panel. It sits
        # at whichever end the upright rules leave free.
        lost_final = Int(lost_curve[end])
        pct = 100 * lost_final / max(1.0, Float64(df.Ground_Total[end]) + lost_final)
        lost_text =
            lost_final == 0 ? "0 lost (0 %)" :
            "$lost_final lost ($(round(pct, sigdigits = 3)) %)"
        side = PlotTheme.annotation_side(
            upright_rules(ctx),
            0.0,
            max_x_h,
            PlotTheme.annotation_fraction(style, lost_text),
        )
        text!(
            ax3,
            side === :right ? 0.985 : 0.015,
            0.88,
            text = lost_text,
            space = :relative,
            align = (side, :top),
            fontsize = style.fontsize_annotation,
            color = PlotTheme.COLOR_LOST,
        )
        push!(axes_to_link, ax3)
        hidexdecorations!(ax2, grid = false, ticks = false)
    end
    hidexdecorations!(ax1, grid = false, ticks = false)

    # One aligned label column: reserve equal tick-label width on all
    # stacked axes (the Lost strip's 1-digit ticks would otherwise pull
    # its ylabel inward relative to the 4-digit panels above).
    foreach(
        ax -> ax.yticklabelspace = PlotTheme.scaled(style, TICK_LABEL_SPACE),
        axes_to_link,
    )

    add_figure_legend!(fig; style = style, legend_flags...)
    linkxaxes!(axes_to_link...)

    rows = [1 => style.panel_height, 2 => style.panel_height]
    ctx.show_lost_panel && push!(rows, 3 => style.strip_height)
    PlotTheme.size_to_panels!(fig, rows...)

    return PlotTheme.save_figure(fig, plots_dir, "mission_summary_global"; formats, suffix)
end

"""
    plot_session(ctx::PlotContext, window::TelemetryCore.ContactWindow, stem::String; style, plots_dir, formats, suffix) -> Union{Nothing,String}

Renders the session figure of one contact `window` — a nominal pass or a
low-latency period: smooth nominal and effective capacity with the onboard
buffer on a twin axis, and the batches received within the window (total
and archive share) with ✕ pins and a count badge for any losses — to
`<run_dir>/plots/session_<stem>_detail.png` with a vector PDF twin
([`session_figure_stems`](@ref) names the stems). Returns `nothing` when
the window lies outside the recorded span or holds fewer than two metrics
rows. Must run inside the telemetry theme.
"""
function plot_session(
    ctx::PlotContext,
    window::TelemetryCore.ContactWindow,
    stem::String;
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
    plots_dir::String = joinpath(ctx.run_dir, "plots"),
    formats = ("png", "pdf"),
    suffix::String = "",
)
    df = ctx.df
    max_x_h = max(ctx.df_x[end], 1.0)
    min_sess_dt = window.start
    max_sess_dt = window.stop
    min_sess_h = hours_since(min_sess_dt, ctx.t_start)
    max_sess_h = hours_since(max_sess_dt, ctx.t_start)
    # Windows entirely outside the recorded mission span produce nothing.
    (max_sess_h <= 0.0 || min_sess_h >= max_x_h) && return nothing

    in_window = (df.SimTime .>= min_sess_dt) .& (df.SimTime .<= max_sess_dt)
    session_df = df[in_window, :]
    length(session_df.SimTime) < 2 && return nothing

    window_ms = (max_sess_dt - min_sess_dt).value
    t_smooth_dt =
        [min_sess_dt + Millisecond(round(Int, (j - 1) * window_ms / 199)) for j in 1:200]
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

    # Provisional height: size_to_panels! sets it once the layout is complete.
    fig = Figure(size = (style.width, style.width))

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

    shade_disruptions!(ax_s1, min_sess_h, max_sess_h, ctx.disruption_spans; style)
    shade_spans!(ax_s1, min_sess_h, max_sess_h, ctx.outage_spans; style)
    shade_generation_gaps!(ax_s1, min_sess_h, max_sess_h, ctx; style)
    mark_events!(ax_s1, min_sess_h, max_sess_h, ctx.marker_times; style)
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
        yticks = PlotTheme.UpperPrunedTicks(),
        # HH:MM labels crowd at session resolution; rotation is applied
        # here rather than in the global theme (rule: rotate crowded labels
        # only).
        xticklabelrotation = π / 4,
    )
    xlims!(ax_s2, min_sess_h, max_sess_h)
    y_max_s2 = max(10.0, 1.2 * maximum(plot_gnd))
    ylims!(ax_s2, 0, y_max_s2)

    shade_disruptions!(ax_s2, min_sess_h, max_sess_h, ctx.disruption_spans; style)
    shade_spans!(ax_s2, min_sess_h, max_sess_h, ctx.outage_spans; style)
    shade_generation_gaps!(ax_s2, min_sess_h, max_sess_h, ctx; style)
    mark_events!(ax_s2, min_sess_h, max_sess_h, ctx.marker_times; style)

    band!(
        ax_s2,
        plot_x,
        zeros(length(plot_x)),
        plot_gnd,
        color = (PlotTheme.COLOR_LIVE, PlotTheme.FILL_ALPHA),
    )
    stairs!(
        ax_s2,
        plot_x,
        plot_gnd,
        color = PlotTheme.COLOR_LIVE,
        linewidth = style.linewidth_edge,
    )
    band!(
        ax_s2,
        plot_x,
        zeros(length(plot_x)),
        plot_ground_archive,
        color = (PlotTheme.COLOR_ARCHIVE, PlotTheme.FILL_ALPHA),
    )
    stairs!(
        ax_s2,
        plot_x,
        plot_ground_archive,
        color = PlotTheme.COLOR_ARCHIVE,
        linewidth = style.linewidth_edge,
    )

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
            fill(SESSION_PIN_HEIGHT * y_max_s2, length(inc)),
            marker = :xcross,
            color = PlotTheme.COLOR_LOST,
            markersize = style.markersize,
        )
        # The left corner belongs to the low-latency note when there is one,
        # so the count only moves left when that corner is free.
        lost_text = "$n_lost_sess lost this session"
        side =
            window.low_latency ? :right :
            PlotTheme.annotation_side(
                upright_rules(ctx),
                min_sess_h,
                max_sess_h,
                PlotTheme.annotation_fraction(style, lost_text),
            )
        text!(
            ax_s2,
            side === :right ? 0.985 : 0.015,
            0.985,
            text = lost_text,
            space = :relative,
            align = (side, :top),
            fontsize = style.fontsize_annotation,
            color = PlotTheme.COLOR_LOST,
        )
    end

    if window.low_latency
        text!(
            ax_s2,
            0.015,
            0.985,
            text = "Low-latency period" *
                   (isempty(window.label) ? "" : " ($(window.label))") *
                   ", capacity $(round(Int, 100 * window.capacity)) %",
            space = :relative,
            align = (:left, :top),
            fontsize = style.fontsize_annotation,
        )
    end

    hidexdecorations!(ax_s1, grid = false, ticks = false)
    foreach(
        ax -> ax.yticklabelspace = PlotTheme.scaled(style, TICK_LABEL_SPACE),
        (ax_s1, ax_s2),
    )

    add_figure_legend!(
        fig;
        style = style,
        degraded = sess_degraded,
        blackout = spans_overlap(ctx.disruption_spans, min_sess_h, max_sess_h, 1, 2),
        ramp = spans_overlap(ctx.disruption_spans, min_sess_h, max_sess_h, 2, 3),
        outage = spans_overlap(ctx.outage_spans, min_sess_h, max_sess_h, 1, 2),
        scheduled_gap = spans_overlap(
            ctx.scheduled_gap_spans,
            min_sess_h,
            max_sess_h,
            1,
            2,
        ),
        recorder = spans_overlap(ctx.recorder_spans, min_sess_h, max_sess_h, 1, 2),
        marker = any(x -> min_sess_h <= x <= max_sess_h, ctx.marker_times),
        lost = n_lost_sess > 0 ? :marks : :none,
    )
    linkxaxes!(ax_s1, ax_s2)

    PlotTheme.size_to_panels!(fig, 1 => style.panel_height, 2 => style.panel_height)

    return PlotTheme.save_figure(fig, plots_dir, "session_$(stem)_detail"; formats, suffix)
end

"""
    RASTER_PX_PER_UNIT

Pixel density at which the batch-state raster is embedded in a vector
export, equal to the density of the PNG twin.
"""
const RASTER_PX_PER_UNIT = 4

"""
    RASTER_STATES

Cell states of the batch-state raster in legend order: the code drawn, the
legend label, and the color. Codes 0–4 are those of
`masks/telemetry_mask_timeline.csv`; [`plot_state_raster`](@ref) redraws the
ground state of a blind-spot archive batch as code 5, so delivered batches
carry the live and archive colors of every other figure.
"""
const RASTER_STATES = (
    (code = 0x00, label = "Future", color = PlotTheme.COLOR_FUTURE),
    (code = 0x01, label = "Onboard", color = PlotTheme.COLOR_ONBOARD),
    (code = 0x02, label = "Link", color = PlotTheme.COLOR_BANDWIDTH),
    (code = 0x03, label = "Ground (live)", color = PlotTheme.COLOR_LIVE),
    (code = 0x05, label = "Ground (archive)", color = PlotTheme.COLOR_ARCHIVE),
    (code = 0x04, label = "Lost", color = PlotTheme.COLOR_LOST),
)

"""
    archive_batch_ids(run_dir::String) -> Set{Int}

IDs of the batches generated as blind-spot archive, from the `gen` rows of
`events_tx.csv` ([`TelemetryCore.is_archive_batch`](@ref)). Empty when the
run carries no emitter log.
"""
function archive_batch_ids(run_dir::String)
    path = joinpath(run_dir, "events_tx.csv")
    isfile(path) || return Set{Int}()
    events = CSV.read(path, DataFrame)
    return Set{Int}(
        TelemetryCore.batch_id(String(row.Batch)) for row in eachrow(events) if
        row.Event == "gen" && TelemetryCore.is_archive_batch(String(row.Batch))
    )
end

"""
    plot_state_raster(run_dir::String; style, plots_dir, formats, suffix) -> Union{Nothing,String}

Renders `masks/telemetry_mask_timeline.csv` as a raster — one column per
batch, one row per recorded event, one color per state — to
`<plots_dir>/state_raster.png` with a vector twin, and returns its path
(`nothing` when the timeline is absent, so a run that skipped
[`DeepSpaceTelemetry.Masks.generate_telemetry_masks`](@ref) is not an error). Must run inside the
telemetry theme.

The figure is the routing doctrine in one panel: the boundary between the
future wash and the onboard color is generation, each pass turns a block of
columns to the ground color, and within a block the higher batch
identifiers turn first — the LIFO backfill, advancing backwards in batch
identifier. What survives to the top of the figure in the onboard color is
the backlog the run never cleared. Delivered batches are drawn in the live
or the archive color according to the batch family recorded in
`events_tx.csv`.
"""
function plot_state_raster(
    run_dir::String;
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
    plots_dir::String = joinpath(run_dir, "plots"),
    formats = ("png", "pdf"),
    suffix::String = "",
)
    if !isfile(TelemetryCore.mask_timeline_path(run_dir))
        @info "[POST] Batch-state raster skipped: the run has no mask timeline (post_processing.generate_mask_timeline)."
        return nothing
    end
    mask = TelemetryCore.read_mask_timeline(run_dir)
    (nrow(mask) == 0 || DataFrames.ncol(mask) < 2) && return nothing
    cfg = TelemetryCore.load_run_config(run_dir)
    sim = get(cfg, "simulation", Dict{String,Any}())
    t_start = something(
        tryparse(DateTime, string(get(sim, "start_sim_time", ""))),
        DateTime(mask.SimTime[1]),
    )
    hours = [hours_since(DateTime(t), t_start) for t in mask.SimTime]
    states = Matrix{UInt8}(mask[:, 2:end])
    # Delivered archive batches take their own display code (RASTER_STATES).
    archive = archive_batch_ids(run_dir)
    for (j, name) in enumerate(names(mask)[2:end])
        TelemetryCore.batch_id(name) in archive || continue
        column = view(states, :, j)
        column[column .== 0x03] .= 0x05
    end

    return with_theme(PlotTheme.telemetry_theme(style)) do
        raster_figure(states, hours, style, plots_dir, formats, suffix)
    end
end

# Figure-product method (TelemetryCore.FIGURE_PRODUCTS).
function TelemetryCore.render_figure_product(
    ::Val{:state_raster},
    run_dir::String,
    post_processing::NamedTuple,
    ground::NamedTuple;
    write_tables::Bool = true,
    kwargs...,
)
    return plot_state_raster(run_dir; kwargs...)
end

"""
    raster_figure(states, hours, style, plots_dir, formats, suffix) -> String

The raster itself, once [`plot_state_raster`](@ref) has read the timeline:
`states` is one row per recorded event and one column per batch, `hours` the
mission hour of each row. `states` carries the display codes of
[`RASTER_STATES`](@ref); the legend lists the states present. Must run inside
the telemetry theme.
"""
function raster_figure(
    states::Matrix{UInt8},
    hours::Vector{Float64},
    style::PlotTheme.PlotStyle,
    plots_dir::String,
    formats,
    suffix::String,
)
    # Provisional height: size_to_panels! sets it once the layout is complete.
    fig = Figure(size = (style.width, style.width))
    tick_values, tick_labels, time_label = mission_time_ticks(max(maximum(hours), 1.0))
    ax = Axis(
        fig[1, 1],
        xlabel = "Batch ID",
        ylabel = time_label,
        yticks = (tick_values, tick_labels),
    )
    by_code = sort(collect(RASTER_STATES); by = s -> s.code)
    # `rasterize` embeds the cells as one image in a vector export. Drawn as
    # paths, one rectangle per cell, a week-long run gives a PDF of over 10 MB.
    heatmap!(
        ax,
        1:size(states, 2),
        hours,
        permutedims(states);
        colormap = cgrad([s.color for s in by_code]; categorical = true),
        colorrange = (-0.5, 5.5),
        rasterize = RASTER_PX_PER_UNIT,
    )
    # The stroke keeps the near-white Future patch visible.
    shown = [s for s in RASTER_STATES if s.code in states]
    PlotTheme.figure_legend!(
        fig,
        style,
        [
            PolyElement(
                color = s.color,
                strokecolor = PlotTheme.COLOR_GUIDE,
                strokewidth = PlotTheme.scaled(style, 1),
            ) for s in shown
        ],
        [s.label for s in shown],
    )
    PlotTheme.size_to_panels!(fig, 1 => 2 * style.panel_height)
    return PlotTheme.save_figure(fig, plots_dir, "state_raster"; formats, suffix)
end

"""
    session_figure_stems(model, t_start::DateTime, t_end::DateTime) -> Vector{Tuple{String,ContactWindow}}

File-name stems of the session figures of every contact window of `model`
overlapping `[t_start, t_end]` ([`TelemetryCore.contact_windows`](@ref)):
`day<kk>` from the 0-based mission day of the window start, `_low_latency`
appended for low-latency periods, and a letter suffix (`b`, `c`, …) when
several windows of the same kind start on the same day.
"""
function session_figure_stems(
    model::TelemetryCore.VisibilityModel,
    t_start::DateTime,
    t_end::DateTime,
)
    stems = Tuple{String,TelemetryCore.ContactWindow}[]
    seen = Dict{String,Int}()
    for w in TelemetryCore.contact_windows(model, t_start, t_end)
        day_k = max(0, floor(Int, (w.start - t_start).value / TelemetryCore.MS_PER_DAY))
        base = "day$(lpad(day_k, 2, '0'))" * (w.low_latency ? "_low_latency" : "")
        n = get(seen, base, 0)
        seen[base] = n + 1
        push!(stems, (n == 0 ? base : base * ('a' + n), w))
    end
    return stems
end

"""
    generate_mission_plots(run_dir::String; style, plots_dir, formats, suffix) -> Vector{String}

Reads `mission_profile.csv` and renders the mission summary
([`plot_mission_summary`](@ref)) and one session figure per contact window
([`plot_session`](@ref)) into `plots_dir` (default `<run_dir>/plots`) in
`formats` (default PNG + PDF) with the file-name `suffix`, all under the
telemetry theme of `style` ([`PlotTheme.PlotStyle`](@ref)); returns the
paths written. Windows are enumerated from the contact model — the nominal daily
passes, scheduled or generated, and the low-latency periods — not detected
from the effective bandwidth, so a fully blacked-out day still receives
its zero-throughput figure and file names share the summary's 0-based day
coordinates.
"""
function generate_mission_plots(
    run_dir::String;
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
    plots_dir::String = joinpath(run_dir, "plots"),
    formats = ("png", "pdf"),
    suffix::String = "",
)
    @info "[POST] Generating mission and session plots..."
    paths = String[]
    log_path = joinpath(run_dir, "mission_profile.csv")
    if !isfile(log_path)
        @warn "[POST] mission_profile.csv missing in $run_dir — the receiver produced no metrics (component never ran?); skipping this product."
        return paths
    end
    df = TelemetryCore.normalize_profile!(CSV.read(log_path, DataFrame))
    isempty(df) && return paths

    ctx = plot_context(run_dir, df, TelemetryCore.load_run_config(run_dir))
    with_theme(PlotTheme.telemetry_theme(style)) do
        global_path = plot_mission_summary(ctx; style, plots_dir, formats, suffix)
        push!(paths, global_path)
        @info "[POST] Saved mission summary figure: $(relpath(global_path, run_dir))"
        t_end =
            ctx.t_start +
            Millisecond(round(Int, TelemetryCore.MS_PER_HOUR * max(ctx.df_x[end], 1.0)))
        for (stem, window) in session_figure_stems(ctx.vis_model, ctx.t_start, t_end)
            p = plot_session(ctx, window, stem; style, plots_dir, formats, suffix)
            p === nothing || push!(paths, p)
        end
        @info "[POST] Saved session figures."
    end
    return paths
end

end # module MissionFigures
