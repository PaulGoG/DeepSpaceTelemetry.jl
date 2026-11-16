"""
    MetrologyFigures

The figures of the metrology tables ([`Metrology`](@ref)): the alert-latency
curve ([`plot_alert_latency`](@ref)) and the delivery-delay distribution
against the requirement ([`plot_delivery_delay`](@ref)).
"""
module MetrologyFigures

using ..TelemetryCore: TelemetryCore
using ..PlotTheme
using ..Metrology:
    Metrology,
    alert_latency_table,
    delivery_compliance,
    delivery_delay_table,
    discarded_batches,
    marker_latency_table
using CairoMakie:
    CairoMakie,
    @L_str,
    Axis,
    Figure,
    LineElement,
    PolyElement,
    band!,
    lines!,
    stairs!,
    text!,
    with_theme,
    xlims!,
    ylims!
using DataFrames: nrow

"Fill alpha of the alert-latency interquartile bands and of their legend patches."
const QUARTILE_BAND_ALPHA = 0.25

"Axis height of the single-panel metrology figures [`PlotTheme.PlotStyle.panel_height`]."
const SINGLE_PANEL_SHARE = 1.4

"""
Upper y-limit of the delivery-delay figure: the unit fraction plus the
headroom that keeps the top of the curves clear of the frame.
"""
const Y_HEADROOM = 1.05

"""
Relative abscissa the delivery-delay figure's corner annotation reaches left
to. A requirement rule beyond it would pass behind the block
([`annotation_block_top`](@ref)).
"""
const ANNOTATION_BLOCK_LEFT = 0.5

"Relative height at which the delivery-delay figure's corner annotation starts."
const ANNOTATION_BLOCK_BOTTOM = 0.06

"""
    annotation_block_top(style::PlotTheme.PlotStyle, n_lines::Int) -> Float64

Relative height the delivery-delay figure's corner annotation reaches: its
bottom offset plus `n_lines` line advances, against the axis height of the
figure, plus a margin of 0.02. The requirement rule stops here, and its
label is placed above it by [`requirement_label_anchor`](@ref).
"""
annotation_block_top(style::PlotTheme.PlotStyle, n_lines::Int) =
    ANNOTATION_BLOCK_BOTTOM +
    n_lines * PlotTheme.line_advance(style) / (SINGLE_PANEL_SHARE * style.panel_height) +
    0.02

"""
Relative clearance the requirement label of the delivery-delay figure keeps
from the frame, from the curves across its footprint, and from the corner
annotation.
"""
const REQUIREMENT_LABEL_MARGIN = 0.02

"""
    requirement_label_occupancy(curves, xa::Real, xb::Real) -> Vector{Tuple{Float64,Float64}}

Relative height intervals the drawn step curves of the delivery-delay figure
cover over the abscissa band `[xa, xb]`, one per curve present there. `curves`
holds `(x, y, drawn)` triples of non-decreasing step data starting at the
origin, each value holding from its abscissa to the next (the `:post` step
of the drawn stairs); a curve whose last abscissa precedes the band is
absent, one ending inside it covers up to its last value. Heights are
divided by [`Y_HEADROOM`](@ref), the figure's upper limit.
"""
function requirement_label_occupancy(curves, xa::Real, xb::Real)
    intervals = Tuple{Float64,Float64}[]
    for (x, y, drawn) in curves
        drawn && maximum(x) >= xa || continue
        lo = y[searchsortedlast(x, max(xa, 0.0))]
        hi = y[searchsortedlast(x, max(xb, 0.0))]
        push!(intervals, (lo / Y_HEADROOM, hi / Y_HEADROOM))
    end
    return intervals
end

"""
    requirement_label_slot(intervals, floor::Real, extent::Real) -> Union{Nothing,Tuple{Float64,Symbol}}

Free slot for the delivery-delay figure's requirement label on one side of
its rule: the relative ordinate of the anchor and the horizontal alignment
of the rotated text (`:right`, the label hangs from the anchor; `:left`, it
rises from it; `:center`), or `nothing` when the side holds no slot.
`intervals` are the relative height intervals the curves occupy across the
label's footprint on that side ([`requirement_label_occupancy`](@ref)),
`floor` the relative height below which the rule is hidden (the corner
annotation's top, or 0), `extent` the label length as a fraction of the
axis height. The slot is above the highest interval when the room up to the
frame holds the label with [`REQUIREMENT_LABEL_MARGIN`](@ref) at both ends,
else below the lowest when the room down to `floor` does, else the middle
of the widest gap between two intervals when it does.
"""
function requirement_label_slot(
    intervals::AbstractVector{<:Tuple{Real,Real}},
    floor::Real,
    extent::Real,
)
    m = REQUIREMENT_LABEL_MARGIN
    hi = maximum(last, intervals; init = float(floor))
    1 - m - hi >= extent + m && return (1 - m, :right)
    lo = minimum(first, intervals; init = 1.0)
    lo - m - floor >= extent + m && return (floor + m, :left)
    spans = sort([(Float64(a), Float64(b)) for (a, b) in intervals]; by = first)
    best_gap, best_mid, top = 0.0, 0.0, -Inf
    for (a, b) in spans
        if isfinite(top) && a - top > best_gap
            best_gap, best_mid = a - top, (top + a) / 2
        end
        top = max(top, b)
    end
    best_gap >= extent + 2m && return (best_mid, :center)
    return nothing
end

"""
    requirement_label_anchor(left, right, floor_left::Real, floor_right::Real, extent::Real) -> Tuple{Float64,Symbol,Symbol}

Anchor of the delivery-delay figure's vertical requirement label: the
relative ordinate, the horizontal alignment of the rotated text, and the
side of the rule it stands on (`:left` or `:right`). `left` and `right`
hold the height intervals the curves occupy across the label's footprint
on each side ([`requirement_label_occupancy`](@ref)), `floor_left` and
`floor_right` the heights below which the rule is hidden there, `extent`
the label length as a fraction of the axis height. The label takes the
first slot [`requirement_label_slot`](@ref) finds, on the left of the rule
before the right, and the top of the left side when neither holds one.
"""
function requirement_label_anchor(
    left::AbstractVector{<:Tuple{Real,Real}},
    right::AbstractVector{<:Tuple{Real,Real}},
    floor_left::Real,
    floor_right::Real,
    extent::Real,
)
    slot = requirement_label_slot(left, floor_left, extent)
    slot === nothing || return (slot..., :left)
    slot = requirement_label_slot(right, floor_right, extent)
    slot === nothing || return (slot..., :right)
    return (1 - REQUIREMENT_LABEL_MARGIN, :right, :left)
end

"""
    plot_alert_latency(run_dir::String; lookback_hours = 72.0, processing_latency_hours = 1.0, style, plots_dir, formats, suffix) -> Union{Nothing,String}

Renders `<plots_dir>/alert_latency.png` with a vector twin from
[`alert_latency_table`](@ref) and [`marker_latency_table`](@ref): the
Kaplan–Meier median window-completeness latency and its interquartile band
against the look-back, drawn where reached, realized in the archive color
(solid) and counterfactual FIFO in [`PlotTheme.COLOR_COUNTERFACTUAL`](@ref)
(dotted), one [`PlotTheme.COLOR_MARKER`](@ref) curve per event marker, and
the medians at the largest look-back where both are reached annotated with
the censored counts and the ground processing budget
`processing_latency_hours`. Returns the PNG path, or `nothing` when the run
holds no delivered live batch.
"""
function plot_alert_latency(
    run_dir::String;
    lookback_hours::Float64 = 72.0,
    processing_latency_hours::Float64 = 1.0,
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
    plots_dir::String = joinpath(run_dir, "plots"),
    formats = ("png", "pdf"),
    suffix::String = "",
)
    table = alert_latency_table(run_dir; lookback_hours = lookback_hours)
    if isempty(table)
        @warn "[POST] No delivered live batch in $run_dir: alert-latency figure skipped."
        return nothing
    end
    marker_table = marker_latency_table(run_dir; lookback_hours = lookback_hours)

    x = Float64.(table.Lookback_Hours)
    path = ""
    with_theme(PlotTheme.telemetry_theme(style)) do
        fig = Figure(size = (style.width, style.width))
        ax = Axis(
            fig[1, 1],
            xlabel = L"Look-back $\delta$ before the live event [h]",
            ylabel = "Window complete on the ground after [h]",
        )
        # Kaplan–Meier interquartile bands with a thin full-hue edge on both
        # quartiles, the medians on top: realized solid, counterfactual
        # dotted. A quantile not reached is NaN: the lines break there (a
        # NaN vertex is a gap), and a band is drawn per contiguous run of
        # rows where both its quartiles are finite (band! takes no NaN).
        fifo_q25 = Float64.(table.FIFO_KM_Q25_Hours)
        fifo_q75 = Float64.(table.FIFO_KM_Q75_Hours)
        lifo_q25 = Float64.(table.LIFO_KM_Q25_Hours)
        lifo_q75 = Float64.(table.LIFO_KM_Q75_Hours)
        lifo_median = Float64.(table.LIFO_KM_Median_Hours)
        fifo_median = Float64.(table.FIFO_KM_Median_Hours)
        finite_runs(lo, hi) = begin
            ok = isfinite.(lo) .& isfinite.(hi)
            runs = UnitRange{Int}[]
            i = 1
            while i <= length(ok)
                if ok[i]
                    j = i
                    while j < length(ok) && ok[j+1]
                        j += 1
                    end
                    push!(runs, i:j)
                    i = j + 1
                else
                    i += 1
                end
            end
            runs
        end
        for r in finite_runs(fifo_q25, fifo_q75)
            band!(
                ax,
                x[r],
                fifo_q25[r],
                fifo_q75[r],
                color = (PlotTheme.COLOR_COUNTERFACTUAL, QUARTILE_BAND_ALPHA),
            )
        end
        for r in finite_runs(lifo_q25, lifo_q75)
            band!(
                ax,
                x[r],
                lifo_q25[r],
                lifo_q75[r],
                color = (PlotTheme.COLOR_ARCHIVE, QUARTILE_BAND_ALPHA),
            )
        end
        for q in (fifo_q25, fifo_q75)
            lines!(
                ax,
                x,
                q,
                color = PlotTheme.COLOR_COUNTERFACTUAL,
                linestyle = :dot,
                linewidth = style.linewidth_guide,
            )
        end
        for q in (lifo_q25, lifo_q75)
            lines!(
                ax,
                x,
                q,
                color = PlotTheme.COLOR_ARCHIVE,
                linewidth = style.linewidth_guide,
            )
        end
        lines!(ax, x, fifo_median, color = PlotTheme.COLOR_COUNTERFACTUAL, linestyle = :dot)
        lines!(ax, x, lifo_median, color = PlotTheme.COLOR_ARCHIVE)
        # Event markers: one realized curve each in the marker color with
        # cycling line styles (a different family from the population bands).
        marker_elements = LineElement[]
        marker_names = String[]
        marker_peak = 0.0
        styles = (:solid, :dashdot, :dot)
        for (i, label) in
            enumerate(isempty(marker_table) ? String[] : unique(marker_table.Label))
            rows = marker_table[marker_table.Label .== label, :]
            keep = .!ismissing.(rows.LIFO_Hours)
            any(keep) || continue
            line_style = styles[mod1(i, length(styles))]
            ys = Float64.(rows.LIFO_Hours[keep])
            marker_peak = max(marker_peak, maximum(ys))
            lines!(
                ax,
                Float64.(rows.Lookback_Hours[keep]),
                ys,
                color = PlotTheme.COLOR_MARKER,
                linestyle = line_style,
                linewidth = style.linewidth,
            )
            push!(
                marker_elements,
                LineElement(
                    color = PlotTheme.COLOR_MARKER,
                    linestyle = line_style,
                    linewidth = style.linewidth,
                ),
            )
            push!(marker_names, "Marker: $label")
        end
        y_max = max(
            maximum(
                filter(
                    isfinite,
                    vcat(lifo_q25, lifo_q75, fifo_q25, fifo_q75, lifo_median, fifo_median),
                );
                init = 1.0,
            ),
            marker_peak,
        )
        xlims!(ax, 0, maximum(x) > 0 ? maximum(x) : 1.0)
        # A margin below zero, as on the lost strip: a zero realized latency
        # would otherwise draw on the axis frame and read as unplotted.
        ylims!(ax, -0.05 * 1.25 * y_max, 1.25 * y_max)
        # The annotated row: the largest look-back where both Kaplan–Meier
        # medians are reached.
        reached = findlast(
            i ->
                isfinite(table.LIFO_KM_Median_Hours[i]) &&
                isfinite(table.FIFO_KM_Median_Hours[i]),
            1:nrow(table),
        )
        # Two text primitives. MathTeXEngine centers continuation lines, so
        # the LaTeX headline (italic δ) is one line; the plain block starts one
        # line advance below it, since a rich-text block would double the
        # line spacing.
        budget =
            "Ground processing budget: $(round(processing_latency_hours, digits = 1)) h " *
            "on top of every latency"
        if reached === nothing
            headline = "Median window completion not reached within the run"
            body = budget
        else
            last = table[reached, :]
            comparison =
                "$(round(last.LIFO_KM_Median_Hours, digits = 1)) h (realized) vs " *
                "$(round(last.FIFO_KM_Median_Hours, digits = 1)) h (counterfactual); " *
                "Kaplan–Meier medians over $(last.N_Alerts_All) live event" *
                (last.N_Alerts_All == 1 ? "" : "s")
            # The censored counts of that row, and why a curve may stop short.
            notes = String[]
            last.N_Censored_LIFO + last.N_Censored_FIFO > 0 && push!(
                notes,
                "incomplete at the run end: $(last.N_Censored_LIFO) realized, " *
                "$(last.N_Censored_FIFO) counterfactual",
            )
            any(
                c -> any(isnan, c),
                (lifo_q25, lifo_q75, fifo_q25, fifo_q75, lifo_median, fifo_median),
            ) && push!(notes, "a curve stops where its quantile is not reached")
            lookback = round(last.Lookback_Hours, digits = 1)
            headline = L"Waveform back to $\delta$ = %$(lookback) h complete after"
            body = join(
                filter(!isempty, [comparison, uppercasefirst(join(notes, "; ")), budget]),
                "\n",
            )
        end
        text!(
            ax,
            0.02,
            0.97,
            text = headline,
            space = :relative,
            align = (:left, :top),
            fontsize = style.fontsize_annotation,
        )
        text!(
            ax,
            0.02,
            0.97,
            text = body,
            space = :relative,
            align = (:left, :top),
            offset = (0, -PlotTheme.line_advance(style)),
            fontsize = style.fontsize_annotation,
        )
        PlotTheme.figure_legend!(
            fig,
            style,
            vcat(
                Any[
                    [
                        PolyElement(color = (PlotTheme.COLOR_ARCHIVE, QUARTILE_BAND_ALPHA)),
                        LineElement(
                            color = PlotTheme.COLOR_ARCHIVE,
                            linewidth = style.linewidth,
                        ),
                    ],
                    [
                        PolyElement(
                            color = (PlotTheme.COLOR_COUNTERFACTUAL, QUARTILE_BAND_ALPHA),
                        ),
                        LineElement(
                            color = PlotTheme.COLOR_COUNTERFACTUAL,
                            linewidth = style.linewidth,
                            linestyle = :dot,
                        ),
                    ],
                ],
                marker_elements,
            ),
            vcat(
                ["Realized: live FIFO + archive LIFO", "Counterfactual: FIFO drain"],
                marker_names,
            ),
        )
        PlotTheme.size_to_panels!(fig, 1 => SINGLE_PANEL_SHARE * style.panel_height)
        path = PlotTheme.save_figure(fig, plots_dir, "alert_latency"; formats, suffix)
    end
    @info "[POST] Alert-latency metric saved: $(relpath(path, run_dir))."
    return path
end

# Figure-product method (TelemetryCore.FIGURE_PRODUCTS).
function TelemetryCore.render_figure_product(
    ::Val{:alert_latency},
    run_dir::String,
    post_processing::NamedTuple,
    ground::NamedTuple;
    kwargs...,
)
    return plot_alert_latency(
        run_dir;
        lookback_hours = post_processing.alert_lookback_hours,
        processing_latency_hours = ground.processing_latency_hours,
        kwargs...,
    )
end

"""
    plot_delivery_delay(run_dir::String; requirement_hours = 24.0, style, plots_dir, formats, suffix) -> Union{Nothing,String}

Renders `<plots_dir>/delivery_delay.png` with a vector twin from
[`delivery_delay_table`](@ref): the empirical distribution of the
measurement-to-ground delay as the fraction of generated batches on the
ground within a given delay, one curve per batch family and, when both
exist, one for all batches, with the requirement rule and the compliance
summary. The legend is omitted for a single curve. Returns the PNG path, or
`nothing` when the run generated no batch.
"""
function plot_delivery_delay(
    run_dir::String;
    requirement_hours::Float64 = 24.0,
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
    plots_dir::String = joinpath(run_dir, "plots"),
    formats = ("png", "pdf"),
    suffix::String = "",
)
    table = delivery_delay_table(run_dir)
    if nrow(table) == 0
        @warn "[POST] No generated batch in $run_dir: delivery-delay figure skipped."
        return nothing
    end
    discarded = discarded_batches(run_dir)
    summary = delivery_compliance(table, requirement_hours; discarded)
    resolved_percent = round(100 * summary.fraction_within_resolved, digits = 1)
    pending = summary.pending
    annotation = [
        "$(resolved_percent) % of $(summary.generated - pending + discarded) due or " *
        "delivered batches within $(round(requirement_hours, digits = 1)) h",
        "Delivered: median $(round(summary.median_hours, digits = 1)) h, " *
        "95th percentile $(round(summary.p95_hours, digits = 1)) h",
        "$(summary.generated - summary.delivered) undelivered at run end" *
        (pending > 0 ? ", $pending of them not yet due" : ""),
    ]
    discarded > 0 && push!(annotation, "$discarded discarded at the on-board recorder")
    summary.via_low_latency > 0 &&
        push!(annotation, "$(summary.via_low_latency) delivered in low-latency periods")

    # Empirical fraction of *generated* batches delivered within x hours, so
    # an undelivered batch keeps the curve below unity.
    curve(mask) = begin
        delays = sort!(Float64[d for d in table.Delay_Hours[mask] if !ismissing(d)])
        n = count(mask)
        x = vcat(0.0, delays)
        y = vcat(0.0, (1:length(delays)) ./ max(n, 1))
        x, y
    end
    x_live, y_live = curve(table.Live)
    x_arch, y_arch = curve(.!table.Live)
    x_all, y_all = curve(trues(nrow(table)))
    x_max = max(maximum(x_all; init = 0.0), requirement_hours) * 1.15

    path = ""
    with_theme(PlotTheme.telemetry_theme(style)) do
        fig = Figure(size = (style.width, style.width))
        ax = Axis(
            fig[1, 1],
            xlabel = "Measurement-to-ground delay [h]",
            ylabel = "Fraction of generated batches delivered",
        )
        xlims!(ax, 0, x_max)
        ylims!(ax, 0, Y_HEADROOM)
        # The requirement rule stops above the annotation block when it would
        # pass behind it: a requirement beyond every realized delay lands at
        # 1/1.15 ≈ 0.87 of the axis, inside the block's corner. The curves
        # occupy the upper left, so the block stays.
        n_lines = length(annotation)
        block_top = annotation_block_top(style, n_lines)
        crosses_annotation = requirement_hours / x_max > ANNOTATION_BLOCK_LEFT
        lines!(
            ax,
            [requirement_hours, requirement_hours],
            [crosses_annotation ? block_top * Y_HEADROOM : 0.0, Y_HEADROOM],
            color = (PlotTheme.COLOR_GUIDE, 0.8),
            linestyle = :dash,
            linewidth = style.linewidth_guide,
        )
        # One curve per batch family present, and the all-batches aggregate
        # when both exist; the legend follows the same guards. The empirical
        # fraction holds from each delay to the next (`step = :post`; Makie's
        # default `:pre` steps one delay early).
        has_live = count(table.Live) > 0
        has_archive = count(.!table.Live) > 0
        legend_elems = LineElement[]
        legend_labels = String[]
        if has_live && has_archive
            stairs!(ax, x_all, y_all, color = PlotTheme.COLOR_GUIDE, step = :post)
            push!(
                legend_elems,
                LineElement(color = PlotTheme.COLOR_GUIDE, linewidth = style.linewidth),
            )
            push!(legend_labels, "All batches")
        end
        if has_live
            stairs!(ax, x_live, y_live, color = PlotTheme.COLOR_LIVE, step = :post)
            push!(
                legend_elems,
                LineElement(color = PlotTheme.COLOR_LIVE, linewidth = style.linewidth),
            )
            push!(legend_labels, "Live")
        end
        if has_archive
            stairs!(ax, x_arch, y_arch, color = PlotTheme.COLOR_ARCHIVE, step = :post)
            push!(
                legend_elems,
                LineElement(color = PlotTheme.COLOR_ARCHIVE, linewidth = style.linewidth),
            )
            push!(legend_labels, "Archive")
        end
        # Bottom-right corner: the curves occupy the upper-left triangle, so
        # the short lines here clear the data and the requirement label.
        text!(
            ax,
            0.98,
            ANNOTATION_BLOCK_BOTTOM,
            text = join(annotation, "\n"),
            space = :relative,
            align = (:right, :bottom),
            justification = :right,
            fontsize = style.fontsize_annotation,
        )
        # Vertical requirement label in a free slot beside the rule
        # (requirement_label_anchor). The axis spans [0, x_max], so the rule's
        # relative abscissa is exact. The footprint is the rule offset plus the
        # rotated text's height at 1.5 font sizes, over the figure width less
        # its padding; the extent is half an em per character.
        label = "Requirement: $(round(requirement_hours, digits = 1)) h"
        offset = PlotTheme.scaled(style, 8)
        footprint =
            x_max * (offset + 1.5 * style.fontsize_annotation) /
            PlotTheme.legend_width(style)
        curves = (
            (x_all, y_all, has_live && has_archive),
            (x_live, y_live, has_live),
            (x_arch, y_arch, has_archive),
        )
        left = requirement_label_occupancy(
            curves,
            requirement_hours - footprint,
            requirement_hours,
        )
        right = requirement_label_occupancy(
            curves,
            requirement_hours,
            requirement_hours + footprint,
        )
        extent =
            0.5 * style.fontsize_annotation * length(label) /
            (SINGLE_PANEL_SHARE * style.panel_height)
        floor_left = crosses_annotation ? block_top : 0.0
        floor_right =
            (requirement_hours + footprint) / x_max > ANNOTATION_BLOCK_LEFT ? block_top :
            0.0
        y_label, halign, side =
            requirement_label_anchor(left, right, floor_left, floor_right, extent)
        text!(
            ax,
            requirement_hours / x_max,
            y_label,
            text = label,
            space = :relative,
            rotation = π / 2,
            align = (halign, side === :left ? :bottom : :top),
            offset = (side === :left ? -offset : offset, 0),
            fontsize = style.fontsize_annotation,
            color = PlotTheme.COLOR_GUIDE,
        )
        length(legend_labels) > 1 &&
            PlotTheme.figure_legend!(fig, style, legend_elems, legend_labels)
        PlotTheme.size_to_panels!(fig, 1 => SINGLE_PANEL_SHARE * style.panel_height)
        path = PlotTheme.save_figure(fig, plots_dir, "delivery_delay"; formats, suffix)
    end
    @info "[POST] Delivery-delay metric saved: $(relpath(path, run_dir)) ($(resolved_percent) % of due or delivered batches within $(requirement_hours) h)."
    return path
end

# Figure-product method (TelemetryCore.FIGURE_PRODUCTS).
function TelemetryCore.render_figure_product(
    ::Val{:delivery_delay},
    run_dir::String,
    post_processing::NamedTuple,
    ground::NamedTuple;
    kwargs...,
)
    return plot_delivery_delay(
        run_dir;
        requirement_hours = post_processing.delivery_requirement_hours,
        kwargs...,
    )
end

end # module MetrologyFigures
