"""
    Metrology

Analysis metrics derived from a run's ground-truth event logs. The first
metric is the alert-latency curve: for a transient caught in a live batch,
how long after the event the whole look-back window of `δ` before it is on
the ground — under the realized live-FIFO / archive-LIFO doctrine and under
a counterfactual first-in, first-out drain that re-assigns the same service
completions in content order. The second is the measurement-to-ground
delay of every batch against a delivery requirement (the Definition Study
Report's 24 hours). See [`alert_latency_table`](@ref),
[`plot_alert_latency`](@ref), [`delivery_delay_table`](@ref), and
[`plot_delivery_delay`](@ref).
"""
module Metrology

using ..TelemetryCore
using ..PlotTheme
using CSV: CSV
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
using DataFrames: DataFrame, nrow
using Dates: DateTime, Millisecond

"""
    QUARTILE_BAND_ALPHA

Fill alpha of the interquartile bands of the alert-latency figure, shared
by the realized and the counterfactual series and by their legend patches.
"""
const QUARTILE_BAND_ALPHA = 0.25

"""
    SINGLE_PANEL_SHARE

Axis height of the single-panel metrology figures in units of the main-panel
height of the style (`PlotTheme.PlotStyle.panel_height`).
"""
const SINGLE_PANEL_SHARE = 1.4

"""
    Y_HEADROOM

Upper y-limit of the delivery-delay figure: the unit fraction plus the
headroom that keeps the top of the curves clear of the frame.
"""
const Y_HEADROOM = 1.05

"""
    ANNOTATION_BLOCK_LEFT

Relative abscissa the delivery-delay figure's corner annotation reaches left
to. A requirement rule beyond it would pass behind the block
([`annotation_block_top`](@ref)).
"""
const ANNOTATION_BLOCK_LEFT = 0.5

"""
    ANNOTATION_BLOCK_BOTTOM

Relative height at which the delivery-delay figure's corner annotation
starts.
"""
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
    REQUIREMENT_LABEL_MARGIN

Relative clearance the requirement label of the delivery-delay figure keeps
from the frame, from the curves crossing its rule, and from the corner
annotation.
"""
const REQUIREMENT_LABEL_MARGIN = 0.02

"""
    requirement_label_anchor(occupied::AbstractVector{<:Real}, floor::Real, extent::Real) -> Tuple{Float64,Symbol}

Relative ordinate of the anchor of the delivery-delay figure's vertical
requirement label and the horizontal alignment of the rotated text (`:left`,
the label rises from the anchor; `:right`, it hangs from it; `:center`).
`occupied` holds the relative heights of the curves crossing the rule at the
requirement, `floor` the relative height below which the rule is hidden
(the corner annotation's top, or 0), `extent` the label length as a fraction
of the axis height. The label takes the free end of the rule: above the
highest curve when the room up to the frame holds it with
[`REQUIREMENT_LABEL_MARGIN`](@ref) at both ends, else below the lowest curve
when the room down to `floor` does, else the middle of the widest interval
between two curves, else the top regardless.
"""
function requirement_label_anchor(
    occupied::AbstractVector{<:Real},
    floor::Real,
    extent::Real,
)
    m = REQUIREMENT_LABEL_MARGIN
    hi = maximum(occupied; init = float(floor))
    1 - m - hi >= extent + m && return (1 - m, :right)
    lo = minimum(occupied; init = 1.0)
    lo - m - floor >= extent + m && return (floor + m, :left)
    levels = sort(Float64.(occupied))
    best_gap, best_mid = 0.0, 0.0
    for i in 1:(length(levels)-1)
        gap = levels[i+1] - levels[i]
        gap > best_gap && ((best_gap, best_mid) = (gap, (levels[i] + levels[i+1]) / 2))
    end
    best_gap >= extent + 2m && return (best_mid, :center)
    return (1 - m, :right)
end

"""
    quantile_sorted(values::AbstractVector{<:Real}, p::Real) -> Float64

Quantile `p ∈ [0, 1]` of an ascending-sorted vector with linear
interpolation between order statistics (the default definition of
`Statistics.quantile`). `NaN` for an empty vector.
"""
function quantile_sorted(values::AbstractVector{<:Real}, p::Real)
    n = length(values)
    n == 0 && return NaN
    n == 1 && return Float64(values[1])
    h = (n - 1) * clamp(Float64(p), 0.0, 1.0)
    lo = floor(Int, h)
    frac = h - lo
    lo + 1 >= n && return Float64(values[n])
    return Float64(values[lo+1]) + frac * (Float64(values[lo+2]) - Float64(values[lo+1]))
end

"""
    BatchDelivery

One batch in the delivery schedule: identity, content interval, generation
(finalization) instant, realized ground availability (`nothing` when the
batch never reached the ground), and the counterfactual FIFO availability
(`nothing` when the FIFO drain never reaches it within the mission).
"""
struct BatchDelivery
    name::String
    id::Int
    live::Bool
    content_epoch::DateTime
    content_end::DateTime
    generated_at::DateTime
    available_at::Union{Nothing,DateTime}
    fifo_available_at::Union{Nothing,DateTime}
end

"""
    delivery_schedule(run_dir::String) -> Vector{BatchDelivery}

Per-batch delivery bookkeeping from `events_tx.csv`, `events_rx.csv`, and
the batch metadata, sorted by content epoch. The realized availability is
the first `ingested` record of the batch. The counterfactual FIFO
availability re-assigns the realized service completions (the sorted
`ingested` instants) to the batches in content order: each completion goes
to the oldest batch that had been generated by then and is still
undelivered under FIFO — the same link, the same slots, the opposite
discipline, and no live priority. Batches without a recorded content epoch
(pre-`content_epoch` metadata) take `generation − batch span`.
"""
function delivery_schedule(run_dir::String)
    tx = CSV.read(joinpath(run_dir, "events_tx.csv"), DataFrame)
    rx_path = joinpath(run_dir, "events_rx.csv")
    rx =
        isfile(rx_path) ? CSV.read(rx_path, DataFrame) :
        DataFrame(SimTime = DateTime[], Batch = String[], Event = String[])
    physics = TelemetryCore.physics_settings(TelemetryCore.load_run_config(run_dir))
    batch_span =
        Millisecond(round(Int, physics.batch_size * physics.segment_duration_sec * 1000))
    epochs = TelemetryCore.batch_content_epochs(run_dir)

    generated = Dict{String,DateTime}()
    for r in eachrow(tx)
        r.Event == "gen" || continue
        name = String(r.Batch)
        haskey(generated, name) || (generated[name] = DateTime(r.SimTime))
    end
    ingested = Dict{String,DateTime}()
    for r in eachrow(rx)
        r.Event == "ingested" || continue
        name = String(r.Batch)
        haskey(ingested, name) || (ingested[name] = DateTime(r.SimTime))
    end

    names = sort!(collect(keys(generated)); by = TelemetryCore.batch_id)
    epoch_of(name) = get(epochs, name, generated[name] - batch_span)
    sort!(names; by = name -> (epoch_of(name), TelemetryCore.batch_id(name)))

    # Counterfactual FIFO drain over the realized service completions.
    completions = sort!(collect(values(ingested)))
    fifo = Dict{String,DateTime}()
    next = 1
    for t in completions
        # Content order is generation order, so the pool of undelivered
        # batches generated by `t` is a prefix of `names`.
        while next <= length(names) && haskey(fifo, names[next])
            next += 1
        end
        next <= length(names) || break
        generated[names[next]] <= t || continue # nothing onboard yet: slot unused
        fifo[names[next]] = t
    end

    return [
        BatchDelivery(
            name,
            TelemetryCore.batch_id(name),
            TelemetryCore.is_live_batch(name),
            epoch_of(name),
            epoch_of(name) + batch_span,
            generated[name],
            get(ingested, name, nothing),
            get(fifo, name, nothing),
        ) for name in names
    ]
end

"""
    batch_containing(schedule, t::DateTime) -> Union{Nothing,BatchDelivery}

The batch whose content interval `[content_epoch, content_end)` contains
`t`, or `nothing` (before the first batch, inside a generation gap, or after
the last).
"""
function batch_containing(schedule::Vector{BatchDelivery}, t::DateTime)
    idx = searchsortedlast(schedule, t; by = x -> x isa DateTime ? x : x.content_epoch)
    idx == 0 && return nothing
    candidate = schedule[idx]
    return t < candidate.content_end ? candidate : nothing
end

"""
    completion_curves(schedule, alert_idx, t_m, steps, span, first_epoch) -> (real, fifo)

Window-completeness latencies of one alert — the batch `schedule[alert_idx]`
with event instant `t_m` — on the look-back grid `δ = 0, span, …,
steps·span`: for each `δ`, the instant (hours after `t_m`) at which every
batch overlapping `[t_m − δ, t_m)` plus the alert batch itself has reached
the ground, under the realized deliveries (`real`) and the counterfactual
FIFO drain (`fifo`). Entries are `nothing` once the window contains a batch
that never arrived under that doctrine (each curve independently); the
vectors stop where the window would reach before `first_epoch`, and are
empty when the alert batch reached the ground under neither doctrine.
"""
function completion_curves(
    schedule::Vector{BatchDelivery},
    alert_idx::Int,
    t_m::DateTime,
    steps::Int,
    span::Millisecond,
    first_epoch::DateTime,
)
    hours(ms::Millisecond) = ms.value / TelemetryCore.MS_PER_HOUR
    latency(t::Union{Nothing,DateTime}) = t === nothing ? NaN : hours(t - t_m)
    m = schedule[alert_idx]
    real = Union{Nothing,Float64}[]
    fifo = Union{Nothing,Float64}[]
    (m.available_at === nothing && m.fifo_available_at === nothing) && return real, fifo
    # The alert batch itself is always part of the window; the two curves
    # propagate their gaps independently (a realized delivery stays
    # informative when the counterfactual drain never reaches the batch).
    real_max = latency(m.available_at)
    fifo_max = latency(m.fifo_available_at)
    j = alert_idx - 1
    for k in 0:steps
        window_start = t_m - Millisecond(k * span.value)
        window_start < first_epoch && break
        while j >= 1 && schedule[j].content_end > window_start
            b = schedule[j]
            real_max = max(real_max, latency(b.available_at))
            fifo_max = max(fifo_max, latency(b.fifo_available_at))
            j -= 1
        end
        push!(real, isnan(real_max) ? nothing : real_max)
        push!(fifo, isnan(fifo_max) ? nothing : fifo_max)
    end
    return real, fifo
end

"""
    marker_latency_table(run_dir::String; lookback_hours = 72.0) -> DataFrame

Window-completeness latency of every event marker of the run
(`markers.csv`): `Label`, `Marker` (the instant), `Batch` (the batch whose
content span holds it; empty when none does), `Lookback_Hours`, and
`LIFO_Hours` / `FIFO_Hours` — [`completion_curves`](@ref) evaluated with
the marker instant as `t_m`, so the latency counts from the event itself.
Missing values mark an undelivered alert batch or a window containing a
batch that never arrived; one row with `Lookback_Hours = 0` and missing
latencies records a marker outside every batch. Empty when the run has no
markers.
"""
function marker_latency_table(run_dir::String; lookback_hours::Float64 = 72.0)
    markers = TelemetryCore.load_markers(run_dir)
    schedule = delivery_schedule(run_dir)
    (isempty(markers) || isempty(schedule)) && return DataFrame()
    span = schedule[1].content_end - schedule[1].content_epoch
    steps = floor(Int, lookback_hours * TelemetryCore.MS_PER_HOUR / span.value)
    first_epoch = schedule[1].content_epoch
    index_of = Dict(b.name => i for (i, b) in enumerate(schedule))

    labels = String[]
    instants = DateTime[]
    batches = String[]
    lookback = Float64[]
    lifo = Union{Missing,Float64}[]
    fifo = Union{Missing,Float64}[]
    for m in markers
        alert = batch_containing(schedule, m.time)
        real, counter =
            alert === nothing ? (Union{Nothing,Float64}[], Union{Nothing,Float64}[]) :
            completion_curves(
                schedule,
                index_of[alert.name],
                m.time,
                steps,
                span,
                first_epoch,
            )
        if isempty(real)
            push!(labels, m.label)
            push!(instants, m.time)
            push!(batches, alert === nothing ? "" : alert.name)
            push!(lookback, 0.0)
            push!(lifo, missing)
            push!(fifo, missing)
            continue
        end
        for (k, (r, f)) in enumerate(zip(real, counter))
            push!(labels, m.label)
            push!(instants, m.time)
            push!(batches, alert.name)
            push!(lookback, (k - 1) * span.value / TelemetryCore.MS_PER_HOUR)
            push!(lifo, r === nothing ? missing : r)
            push!(fifo, f === nothing ? missing : f)
        end
    end
    return DataFrame(
        Label = labels,
        Marker = instants,
        Batch = batches,
        Lookback_Hours = lookback,
        LIFO_Hours = lifo,
        FIFO_Hours = fifo,
    )
end

"""
    alert_latency_table(run_dir::String; lookback_hours = 72.0) -> DataFrame

Window-completeness latency curves over the look-back grid
`δ = 0, D, 2D, …` (`D` = the batch content span) up to `lookback_hours`.
Every live batch that reached the ground defines an alert whose event
instant `t_m` is the batch's content end (the moment the transient's
samples exist). The look-back window `[t_m − δ, t_m)`, together with the
alert batch itself, is complete on the ground once every batch overlapping
it has arrived; the latency is that completion instant minus `t_m` — for
the realized doctrine and for the counterfactual FIFO drain
([`delivery_schedule`](@ref)) — so `δ ≤ D` gives the delivery delay of the
live batch itself and the curve is non-decreasing in `δ`. Alerts whose window reaches before the first recorded batch, and
alerts whose window contains a batch that never arrived under either
discipline, are excluded at that `δ`; `N_Alerts` counts the contributing
alerts. Columns: `Lookback_Hours`, `N_Alerts`, and the median and 25 % /
75 % quantiles of the latency in hours for `LIFO` (realized) and `FIFO`.
"""
function alert_latency_table(run_dir::String; lookback_hours::Float64 = 72.0)
    schedule = delivery_schedule(run_dir)
    isempty(schedule) && return DataFrame()
    span = schedule[1].content_end - schedule[1].content_epoch
    steps = floor(Int, lookback_hours * TelemetryCore.MS_PER_HOUR / span.value)
    first_epoch = schedule[1].content_epoch
    hours(ms::Millisecond) = ms.value / TelemetryCore.MS_PER_HOUR

    # Per alert, the running completion instants of the window as it grows
    # one batch at a time towards the past; `nothing` once a batch that
    # never arrived enters the window.
    lifo_at = Vector{Vector{Union{Nothing,Float64}}}()
    fifo_at = Vector{Vector{Union{Nothing,Float64}}}()
    for (i, m) in enumerate(schedule)
        (m.live && m.available_at !== nothing && m.fifo_available_at !== nothing) ||
            continue
        real, fifo = completion_curves(schedule, i, m.content_end, steps, span, first_epoch)
        push!(lifo_at, real)
        push!(fifo_at, fifo)
    end

    lookback = Float64[]
    n_alerts = Int[]
    lifo_median = Float64[]
    lifo_q25 = Float64[]
    lifo_q75 = Float64[]
    fifo_median = Float64[]
    fifo_q25 = Float64[]
    fifo_q75 = Float64[]
    for k in 0:steps
        lifo = Float64[]
        fifo = Float64[]
        for (real, counter) in zip(lifo_at, fifo_at)
            k + 1 <= length(real) || continue
            (real[k+1] === nothing || counter[k+1] === nothing) && continue
            push!(lifo, real[k+1])
            push!(fifo, counter[k+1])
        end
        isempty(lifo) && continue
        sort!(lifo)
        sort!(fifo)
        push!(lookback, hours(Millisecond(k * span.value)))
        push!(n_alerts, length(lifo))
        push!(lifo_median, quantile_sorted(lifo, 0.5))
        push!(lifo_q25, quantile_sorted(lifo, 0.25))
        push!(lifo_q75, quantile_sorted(lifo, 0.75))
        push!(fifo_median, quantile_sorted(fifo, 0.5))
        push!(fifo_q25, quantile_sorted(fifo, 0.25))
        push!(fifo_q75, quantile_sorted(fifo, 0.75))
    end
    isempty(lookback) && return DataFrame()
    return DataFrame(
        Lookback_Hours = lookback,
        N_Alerts = n_alerts,
        LIFO_Median_Hours = lifo_median,
        LIFO_Q25_Hours = lifo_q25,
        LIFO_Q75_Hours = lifo_q75,
        FIFO_Median_Hours = fifo_median,
        FIFO_Q25_Hours = fifo_q25,
        FIFO_Q75_Hours = fifo_q75,
    )
end

"""
    plot_alert_latency(run_dir::String; lookback_hours = 72.0, processing_latency_hours = 1.0, style, plots_dir, formats, suffix, write_tables = true) -> Union{Nothing,String}

Writes `<run_dir>/alert_latency.csv` ([`alert_latency_table`](@ref)) and,
when the run has markers, `alert_latency_markers.csv`
([`marker_latency_table`](@ref)); renders `<run_dir>/plots/alert_latency.png`
(with a vector PDF twin): the median window-completeness latency with the
interquartile band (thin full-hue edges on both quartiles) against the
look-back, realized doctrine solid in the archive color, counterfactual
FIFO drain dotted in [`PlotTheme.COLOR_COUNTERFACTUAL`](@ref), one
[`PlotTheme.COLOR_MARKER`](@ref) curve per event marker, the medians at the
largest tabulated look-back annotated together with the ground processing
budget `processing_latency_hours`. Returns the PNG path, or `nothing` when
the run holds no delivered live batch.
"""
function plot_alert_latency(
    run_dir::String;
    lookback_hours::Float64 = 72.0,
    processing_latency_hours::Float64 = 1.0,
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
    plots_dir::String = joinpath(run_dir, "plots"),
    formats = ("png", "pdf"),
    suffix::String = "",
    write_tables::Bool = true,
)
    table = alert_latency_table(run_dir; lookback_hours = lookback_hours)
    if isempty(table)
        @warn "[POST] No delivered live batch in $run_dir — alert-latency metric skipped."
        return nothing
    end
    write_tables &&
        TelemetryCore.safe_csv_write(joinpath(run_dir, "alert_latency.csv"), table)
    marker_table = marker_latency_table(run_dir; lookback_hours = lookback_hours)
    write_tables &&
        !isempty(marker_table) &&
        TelemetryCore.safe_csv_write(
            joinpath(run_dir, "alert_latency_markers.csv"),
            marker_table,
        )

    x = Float64.(table.Lookback_Hours)
    path = ""
    with_theme(PlotTheme.telemetry_theme(style)) do
        fig = Figure(size = (style.width, style.width))
        ax = Axis(
            fig[1, 1],
            xlabel = L"Look-back $\delta$ before the live event [h]",
            ylabel = "Window complete on the ground after [h]",
        )
        # Interquartile bands with a thin full-hue edge on both quartiles,
        # the medians on top: realized solid, counterfactual dotted.
        fifo_q25, fifo_q75 = Float64.(table.FIFO_Q25_Hours), Float64.(table.FIFO_Q75_Hours)
        lifo_q25, lifo_q75 = Float64.(table.LIFO_Q25_Hours), Float64.(table.LIFO_Q75_Hours)
        band!(
            ax,
            x,
            fifo_q25,
            fifo_q75,
            color = (PlotTheme.COLOR_COUNTERFACTUAL, QUARTILE_BAND_ALPHA),
        )
        band!(
            ax,
            x,
            lifo_q25,
            lifo_q75,
            color = (PlotTheme.COLOR_ARCHIVE, QUARTILE_BAND_ALPHA),
        )
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
        lines!(
            ax,
            x,
            Float64.(table.FIFO_Median_Hours),
            color = PlotTheme.COLOR_COUNTERFACTUAL,
            linestyle = :dot,
        )
        lines!(ax, x, Float64.(table.LIFO_Median_Hours), color = PlotTheme.COLOR_ARCHIVE)
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
                    vcat(
                        Float64.(table.LIFO_Q75_Hours),
                        Float64.(table.FIFO_Q75_Hours),
                        Float64.(table.FIFO_Median_Hours),
                    ),
                );
                init = 1.0,
            ),
            marker_peak,
        )
        xlims!(ax, 0, maximum(x) > 0 ? maximum(x) : 1.0)
        # A margin below zero, as on the lost strip: a zero realized latency
        # would otherwise draw on the axis frame and read as unplotted.
        ylims!(ax, -0.05 * 1.25 * y_max, 1.25 * y_max)
        last = table[end, :]
        # Two text primitives: the headline as a LaTeX string (italic δ; a
        # single line, since MathTeXEngine centers continuation lines) and
        # the remaining lines as a plain block one line advance below (a
        # rich-text block would double the line spacing).
        comparison =
            "$(round(last.LIFO_Median_Hours, digits = 1)) h (realized) vs " *
            "$(round(last.FIFO_Median_Hours, digits = 1)) h (counterfactual);"
        population =
            "medians over $(last.N_Alerts) live event" * (last.N_Alerts == 1 ? "" : "s")
        budget = "Ground processing budget: $(round(processing_latency_hours, digits = 1)) h"
        lookback = round(last.Lookback_Hours, digits = 1)
        headline = L"Waveform back to $\delta$ = %$(lookback) h complete after"
        body = comparison * " " * population * "\n" * budget * " on top of every latency"
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
    @info "[POST] Alert-latency metric saved: $(relpath(path, run_dir)) and alert_latency.csv."
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

# --- Delivery delay and the 24-hour requirement ---

"""
    delivery_delay_table(run_dir::String) -> DataFrame

Measurement-to-ground delay of every generated batch: `Batch`, `Live`,
`ContentEnd`, `AvailableAt` (missing when the batch never reached the
ground), `Delay_Hours` = availability minus content end (missing when
undelivered), and `LowLatency` — whether the batch reached the ground
inside a low-latency period of the run's contact model. Built on
[`delivery_schedule`](@ref); rows sorted by content epoch.
"""
function delivery_delay_table(run_dir::String)
    schedule = delivery_schedule(run_dir)
    vis = TelemetryCore.visibility_model(TelemetryCore.load_run_config(run_dir))
    in_low_latency(t::DateTime) = begin
        w = TelemetryCore.active_window(vis, t)
        w !== nothing && w.low_latency
    end
    return DataFrame(
        Batch = [b.name for b in schedule],
        Live = [b.live for b in schedule],
        ContentEnd = [b.content_end for b in schedule],
        AvailableAt = [
            b.available_at === nothing ? missing : b.available_at for b in schedule
        ],
        Delay_Hours = [
            b.available_at === nothing ? missing :
            (b.available_at - b.content_end).value / TelemetryCore.MS_PER_HOUR for
            b in schedule
        ],
        LowLatency = [
            b.available_at !== nothing && in_low_latency(b.available_at) for b in schedule
        ],
    )
end

"""
    delivery_compliance(table::DataFrame, requirement_hours::Float64) -> NamedTuple

Summary of a [`delivery_delay_table`](@ref) against a delivery requirement:
`generated`, `delivered`, `within` (delivered within `requirement_hours` of
measurement), `via_low_latency` (delivered inside a low-latency period),
`fraction_within` (of all generated batches — an undelivered batch is
non-compliant), `median_hours`, and `p95_hours` of the delivered
delays (`NaN` when nothing was delivered).
"""
function delivery_compliance(table::DataFrame, requirement_hours::Float64)
    delays = sort!(Float64[d for d in table.Delay_Hours if !ismissing(d)])
    generated = nrow(table)
    delivered = length(delays)
    within = count(<=(requirement_hours), delays)
    return (
        generated = generated,
        delivered = delivered,
        within = within,
        via_low_latency = count(table.LowLatency),
        fraction_within = generated == 0 ? NaN : within / generated,
        median_hours = quantile_sorted(delays, 0.5),
        p95_hours = quantile_sorted(delays, 0.95),
    )
end

"""
    plot_delivery_delay(run_dir::String; requirement_hours = 24.0, style, plots_dir, formats, suffix, write_tables = true) -> Union{Nothing,String}

Writes `<run_dir>/delivery_delay.csv` ([`delivery_delay_table`](@ref)) and
renders `<run_dir>/plots/delivery_delay.png` (vector PDF twin): the
empirical distribution of the measurement-to-ground delay — the fraction
of generated batches on the ground within a given delay, live and archive
batches as separate curves plus the all-batches aggregate when both
families exist — with the requirement marked and the compliance summary
annotated. The legend lists exactly the curves drawn and is omitted when
only one is. Returns the PNG path, or `nothing` when the run generated no
batch.
"""
function plot_delivery_delay(
    run_dir::String;
    requirement_hours::Float64 = 24.0,
    style::PlotTheme.PlotStyle = PlotTheme.PlotStyle(),
    plots_dir::String = joinpath(run_dir, "plots"),
    formats = ("png", "pdf"),
    suffix::String = "",
    write_tables::Bool = true,
)
    table = delivery_delay_table(run_dir)
    if nrow(table) == 0
        @warn "[POST] No generated batch in $run_dir — delivery-delay metric skipped."
        return nothing
    end
    write_tables &&
        TelemetryCore.safe_csv_write(joinpath(run_dir, "delivery_delay.csv"), table)
    summary = delivery_compliance(table, requirement_hours)

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
        # otherwise pass behind it — a requirement beyond every realized delay
        # lands at 0.87 of the axis, inside the block's corner. The curves
        # occupy the upper-left, so the block cannot move instead.
        n_lines = summary.via_low_latency > 0 ? 4 : 3
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
        # One curve per batch family present, the all-batches aggregate only
        # when both families exist (it coincides with the single family
        # otherwise); the legend entries follow the same guards.
        has_live = count(table.Live) > 0
        has_archive = count(.!table.Live) > 0
        legend_elems = LineElement[]
        legend_labels = String[]
        if has_live && has_archive
            stairs!(ax, x_all, y_all, color = PlotTheme.COLOR_GUIDE)
            push!(
                legend_elems,
                LineElement(color = PlotTheme.COLOR_GUIDE, linewidth = style.linewidth),
            )
            push!(legend_labels, "All batches")
        end
        if has_live
            stairs!(ax, x_live, y_live, color = PlotTheme.COLOR_LIVE)
            push!(
                legend_elems,
                LineElement(color = PlotTheme.COLOR_LIVE, linewidth = style.linewidth),
            )
            push!(legend_labels, "Live")
        end
        if has_archive
            stairs!(ax, x_arch, y_arch, color = PlotTheme.COLOR_ARCHIVE)
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
            text = "$(round(100 * summary.fraction_within, digits = 1)) % of $(summary.generated) batches within " *
                   "$(round(requirement_hours, digits = 1)) h\n" *
                   "Median $(round(summary.median_hours, digits = 1)) h, " *
                   "95th percentile $(round(summary.p95_hours, digits = 1)) h\n" *
                   "$(summary.generated - summary.delivered) undelivered at run end" *
                   (
                       summary.via_low_latency > 0 ?
                       "\n$(summary.via_low_latency) delivered in low-latency periods" : ""
                   ),
            space = :relative,
            align = (:right, :bottom),
            justification = :right,
            fontsize = style.fontsize_annotation,
        )
        # Requirement label vertical along the rule on its left, at the free
        # end of the rule: the drawn curves are evaluated at the requirement
        # (a curve ending before it occupies nothing there) in relative
        # units of the axis, against the label length at half an em per
        # character; the axis spans [0, x_max], so the rule's relative
        # abscissa is exact.
        label = "Requirement: $(round(requirement_hours, digits = 1)) h"
        occupied = Float64[]
        for (x, y, drawn) in (
            (x_all, y_all, has_live && has_archive),
            (x_live, y_live, has_live),
            (x_arch, y_arch, has_archive),
        )
            drawn && maximum(x) >= requirement_hours || continue
            push!(occupied, y[searchsortedlast(x, requirement_hours)] / Y_HEADROOM)
        end
        extent =
            0.5 * style.fontsize_annotation * length(label) /
            (SINGLE_PANEL_SHARE * style.panel_height)
        y_label, halign =
            requirement_label_anchor(occupied, crosses_annotation ? block_top : 0.0, extent)
        text!(
            ax,
            requirement_hours / x_max,
            y_label,
            text = label,
            space = :relative,
            rotation = π / 2,
            align = (halign, :bottom),
            offset = (-PlotTheme.scaled(style, 8), 0),
            fontsize = style.fontsize_annotation,
            color = PlotTheme.COLOR_GUIDE,
        )
        length(legend_labels) > 1 &&
            PlotTheme.figure_legend!(fig, style, legend_elems, legend_labels)
        PlotTheme.size_to_panels!(fig, 1 => SINGLE_PANEL_SHARE * style.panel_height)
        path = PlotTheme.save_figure(fig, plots_dir, "delivery_delay"; formats, suffix)
    end
    @info "[POST] Delivery-delay metric saved: $(relpath(path, run_dir)) and delivery_delay.csv ($(round(100 * summary.fraction_within, digits = 1)) % within $(requirement_hours) h)."
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

end # module Metrology
