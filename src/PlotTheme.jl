"""
    PlotTheme

Plotting standards shared by every figure: the Okabe–Ito semantic palette,
the standard figure layout with its uniform print scaling
([`PlotStyle`](@ref)), the measured legend and figure sizing
([`figure_legend!`](@ref), [`size_to_panels!`](@ref)), and the CairoMakie
theme ([`telemetry_theme`](@ref)). Lengths are Makie units (1/96 inch) at
the standard layout, which [`PlotStyle`](@ref) scales.
"""
module PlotTheme

using CairoMakie:
    CairoMakie,
    Makie,
    @colorant_str,
    Fixed,
    Legend,
    Theme,
    resize_to_layout!,
    rowsize!,
    save,
    with_theme
using MathTeXEngine: texfont

# Okabe–Ito colorblind-safe palette: one semantic color per quantity,
# consistent across every figure and the animation.

"Near-real-time (live, FIFO-priority) batches: Okabe–Ito sky blue."
const COLOR_LIVE = colorant"#56B4E9"

"Blind-spot archive (LIFO-backfilled) batches: Okabe–Ito bluish green."
const COLOR_ARCHIVE = colorant"#009E73"

"DSN link-capacity (bandwidth) curve: Okabe–Ito blue."
const COLOR_BANDWIDTH = colorant"#0072B2"

"Onboard SSD backlog curve, dashed so it survives grayscale: Okabe–Ito orange."
const COLOR_ONBOARD = colorant"#E69F00"

"Permanently lost (retry-exhausted) batches, drawn as ✕: Okabe–Ito vermillion."
const COLOR_LOST = colorant"#D55E00"

"Counterfactual FIFO drain of the alert-latency figure, dotted: Okabe–Ito reddish purple."
const COLOR_COUNTERFACTUAL = colorant"#CC79A7"

"""
Neutral base of the disruption shading (blackout wash fading to zero alpha over the
recovery ramp, dashed edges), kept apart from the series palette.
"""
const COLOR_DISRUPTION = :black

"""
Neutral base of the shading of unscheduled component outages (low-alpha wash, dotted
edges), apart from the series palette and, by line style, from the disruption shading.
"""
const COLOR_OUTAGE = :black

"""
Event markers: their upright rules in the mission figures and their realized latency
curves in the alert-latency figure, apart from the population bands and told apart by
cycling line styles.
"""
const COLOR_MARKER = :black

"""
Neutral gray of population aggregates and reference guides: the all-batches delivery
curve and the delivery-requirement rule with its label.
"""
const COLOR_GUIDE = colorant"gray40"

"""
Not-yet-generated cells of the batch-state raster: a near-white that reads as absence,
so the generation front is the edge of the drawn area.
"""
const COLOR_FUTURE = colorant"#F5F5F5"

# --- Standard layout ---
# Every figure is composed once, at the standard layout below, and scaled as
# a whole: `PlotStyle(scale)` multiplies every length by the same factor, so
# a figure printed narrower is a miniature of the standard one and no two of
# its elements can newly meet. Makie layout units are 1/96 inch; a vector
# export enters LaTeX at native size.

"""
Width of every figure, shared by the stacked time-series dashboards of a mission so that
sibling figures print with identical type.
"""
const FIGURE_WIDTH = 1200

"Axis height of a main panel."
const PANEL_HEIGHT = 380

"Axis height of an auxiliary strip (the Lost strip of the mission summary)."
const STRIP_HEIGHT = 150

"Font size of axis labels, legends, and legend headers."
const FONTSIZE = 26

"Tick-label font size."
const FONTSIZE_TICK = 22

"In-axis annotation font size."
const FONTSIZE_ANNOTATION = 21

"Data-series line width."
const LINEWIDTH_DATA = 3.0

"Width of guide lines: thresholds, requirement and event-marker rules, window edges."
const LINEWIDTH_GUIDE = 1.5

"Width of the same-hue edge of an area fill."
const LINEWIDTH_EDGE = 2.5

"Marker size of event pins and legend glyphs, the same in every figure."
const MARKERSIZE_DATA = 14

"Alpha of the fills under cumulative curves, edged in full hue ([`LINEWIDTH_EDGE`](@ref))."
const FILL_ALPHA = 0.35

"Outer padding of every figure."
const FIGURE_PADDING = 10

"""
Right-hand padding of every figure: the outer padding plus half a tick label, which an
x tick on the axis frame pushes past it.
"""
const FIGURE_PADDING_RIGHT = 45

"""
Estimated share of the figure width left to a stacked panel's axis by the y-axis
decorations of both sides and the padding; used only by [`annotation_fraction`](@ref).
"""
const AXIS_WIDTH_SHARE = 0.84

"""
    PlotStyle

Lengths of one figure set, all in Makie units: `scale` relative to the
standard layout, the figure `width`, the axis heights `panel_height` and
`strip_height`, the font sizes (`fontsize` for axis labels and legends,
`fontsize_tick`, `fontsize_annotation`), the line widths (`linewidth` for
data, `linewidth_guide` for reference lines and window edges,
`linewidth_edge` for the edge of an area fill), and `markersize`.
`PlotStyle(scale)` multiplies the standard layout by `scale` throughout;
`PlotStyle()` is the standard layout itself.
"""
struct PlotStyle
    scale::Float64
    width::Int
    panel_height::Float64
    strip_height::Float64
    fontsize::Float64
    fontsize_tick::Float64
    fontsize_annotation::Float64
    linewidth::Float64
    linewidth_guide::Float64
    linewidth_edge::Float64
    markersize::Float64
end

function PlotStyle(scale::Real = 1.0)
    scale > 0 || throw(ArgumentError("PlotStyle scale must be > 0 (got $scale)."))
    s = Float64(scale)
    return PlotStyle(
        s,
        round(Int, FIGURE_WIDTH * s),
        PANEL_HEIGHT * s,
        STRIP_HEIGHT * s,
        FONTSIZE * s,
        FONTSIZE_TICK * s,
        FONTSIZE_ANNOTATION * s,
        LINEWIDTH_DATA * s,
        LINEWIDTH_GUIDE * s,
        LINEWIDTH_EDGE * s,
        MARKERSIZE_DATA * s,
    )
end

"""
    scaled(style::PlotStyle, length::Real) -> Float64

`length`, given in Makie units at the standard layout, at the scale of
`style`. Every absolute length a figure sets by hand — a reserved tick-label
width, a gap, an offset — goes through here.
"""
scaled(style::PlotStyle, length::Real) = style.scale * length

"""
    style_for_width(column_width_mm::Real) -> PlotStyle

The [`PlotStyle`](@ref) of a figure printed `column_width_mm` wide (Makie
units are 1/96 inch). At 178 mm the axis labels print at ≈ 11 pt and the
tick labels at ≈ 9 pt; at the 100 mm floor of the publication export, at
≈ 6 pt and ≈ 5 pt.
"""
style_for_width(column_width_mm::Real) =
    PlotStyle(column_width_mm / 25.4 * 96 / FIGURE_WIDTH)

"""
    line_advance(style::PlotStyle) -> Float64

Vertical advance between two lines of in-axis annotation text in Makie
units: the line height of the theme's text face (`height / units_per_EM`,
the multiplier Makie applies to multi-line text) times the annotation
font size. Places a second text primitive directly under a first, e.g. a
plain block below a LaTeX headline.
"""
function line_advance(style::PlotStyle)
    face = texfont(:text)
    return face.height / face.units_per_EM * style.fontsize_annotation
end

"""
    annotation_fraction(style::PlotStyle, text) -> Float64

Width of the single-line annotation `text` as a fraction of the axis it sits
in, at half an em per character (the mean advance of the text face) against
[`AXIS_WIDTH_SHARE`](@ref) of the figure width, capped at 0.45 — beyond that
neither end of the axis is free. Independent of the scale of `style`.
Nothing is positioned with it; [`annotation_side`](@ref) chooses an end of
the axis by it.
"""
annotation_fraction(style::PlotStyle, text) = min(
    0.45,
    0.5 * style.fontsize_annotation * length(string(text)) /
    (AXIS_WIDTH_SHARE * style.width),
)

"""
    annotation_side(occupied, x_lo, x_hi, fraction) -> Symbol

End of the axis for an in-axis annotation block of relative width
`fraction` ([`annotation_fraction`](@ref)): `:left` when one of the
`occupied` x positions (upright rules, shaded edges) lies within `fraction`
of the right edge and none within `fraction` of the left edge, else
`:right`.
"""
function annotation_side(occupied, x_lo::Real, x_hi::Real, fraction::Real)
    span = x_hi - x_lo
    span > 0 || return :right
    in_right = any(x -> (x - x_lo) / span > 1 - fraction, occupied)
    in_left = any(x -> (x - x_lo) / span < fraction, occupied)
    return in_right && !in_left ? :left : :right
end

"""
Relative distance between an in-axis annotation block and the axis frame at
the end it is aligned to ([`annotation_anchor`](@ref)).
"""
const ANNOTATION_EDGE_INSET = 0.015

"""
    annotation_anchor(occupied, x_lo, x_hi, fraction) -> Tuple{Float64,Symbol}

Relative x position and horizontal alignment of an in-axis annotation block
of relative width `fraction` ([`annotation_fraction`](@ref)) on an axis
spanning `[x_lo, x_hi]`, clear of the `occupied` x positions (upright rules
and shaded edges; those outside the axis are ignored). The block with its
two insets ([`ANNOTATION_EDGE_INSET`](@ref)) takes the right end, else the
left end, else the middle of the widest interval between consecutive
positions; it stays at the right end when no interval holds it.

```jldoctest
julia> DeepSpaceTelemetry.PlotTheme.annotation_anchor([0.5, 9.5], 0.0, 10.0, 0.2)
(0.5, :center)
```
"""
function annotation_anchor(occupied, x_lo::Real, x_hi::Real, fraction::Real)
    right = (1 - ANNOTATION_EDGE_INSET, :right)
    span = x_hi - x_lo
    span > 0 || return right
    positions = sort!(Float64[(x - x_lo) / span for x in occupied if x_lo <= x <= x_hi])
    needed = fraction + 2 * ANNOTATION_EDGE_INSET
    any(p -> p > 1 - needed, positions) || return right
    any(p -> p < needed, positions) || return (ANNOTATION_EDGE_INSET, :left)
    widest, center = 0.0, 0.0
    for i in 2:length(positions)
        width = positions[i] - positions[i-1]
        if width > widest
            widest, center = width, (positions[i] + positions[i-1]) / 2
        end
    end
    return widest >= needed ? (center, :center) : right
end

"""
Magnitude from which the tick labels of a count axis are written with a power
of ten ([`power_of_ten_labels`](@ref), [`count_tickformat`](@ref)).
"""
const POWER_OF_TEN_THRESHOLD = 1.0e4

"""
    power_of_ten_labels(values) -> Vector{String}

Tick labels with one common power of ten, that of the largest magnitude
among `values`: `1×10ⁿ` is written `10ⁿ`, zero is `0`, a mantissa carries at
most three significant digits without trailing zeros, and a negative value
takes the typographic minus.

```jldoctest
julia> DeepSpaceTelemetry.PlotTheme.power_of_ten_labels([0, 10_000, 20_000, 30_000])
4-element Vector{String}:
 "0"
 "10⁴"
 "2×10⁴"
 "3×10⁴"
```
"""
function power_of_ten_labels(values)
    isempty(values) && return String[]
    top = maximum(abs, values)
    top > 0 || return fill("0", length(values))
    exponent = floor(Int, log10(top))
    return [power_of_ten_label(v / 10.0^exponent, exponent) for v in values]
end

"""
    power_of_ten_label(mantissa::Real, exponent::Integer) -> String

One label of [`power_of_ten_labels`](@ref): `mantissa × 10^exponent` in the
house style.
"""
function power_of_ten_label(mantissa::Real, exponent::Integer)
    m = round(Float64(mantissa), sigdigits = 3)
    m == 0 && return "0"
    superscript = join(
        c == '-' ? '⁻' : "⁰¹²³⁴⁵⁶⁷⁸⁹"[nextind("⁰¹²³⁴⁵⁶⁷⁸⁹", 0, c - '0' + 1)] for
        c in string(exponent)
    )
    sign = m < 0 ? "−" : ""
    a = abs(m)
    a == 1 && return sign * "10" * superscript
    digits = isinteger(a) ? string(Int(a)) : string(a)
    return sign * digits * "×10" * superscript
end

"""
    count_tickformat(top::Real)

Tick format of a count axis that reaches `top`: [`power_of_ten_labels`](@ref)
from [`POWER_OF_TEN_THRESHOLD`](@ref) on, Makie's own format below it, so
that axes under the threshold are drawn as before.
"""
count_tickformat(top::Real) =
    abs(top) >= POWER_OF_TEN_THRESHOLD ? power_of_ten_labels : Makie.automatic

"""
Fraction of the axis range below the upper limit within which
[`UpperPrunedTicks`](@ref) discards a tick.
"""
const TICK_PRUNE_FRACTION = 0.05

"""
    UpperPrunedTicks()

Tick locator of the lower panel of a stacked pair: the ticks of the default
locator on the axis range, without those within [`TICK_PRUNE_FRACTION`](@ref)
of the upper limit. A tick label at the upper limit of the lower panel meets
the `0` of the panel above across the row gap; pruning it is the stacked-axes
rule (matplotlib's `prune = "upper"`). Passed as `yticks = UpperPrunedTicks()`.
"""
struct UpperPrunedTicks end

function Makie.get_tickvalues(::UpperPrunedTicks, vmin::Real, vmax::Real)
    ticks = Makie.get_tickvalues(Makie.automatic, identity, vmin, vmax)
    return filter(t -> t < vmax - TICK_PRUNE_FRACTION * (vmax - vmin), ticks)
end

"""
    fit_legend!(legend, available_width::Real) -> Int

Sets `legend.nbanks` to the smallest row count at which the legend, as Makie
itself measures it, is no wider than `available_width`, and returns that
count. A legend whose longest group cannot fit keeps one entry per row.
"""
function fit_legend!(legend, available_width::Real)
    longest = maximum(group -> length(last(group)), legend.entrygroups[]; init = 1)
    for banks in 1:longest
        legend.nbanks[] = banks
        legend.layoutobservables.autosize[][1] <= available_width && return banks
    end
    return longest
end

"""
    figure_legend!(fig, style::PlotStyle, elements, labels) -> Legend
    figure_legend!(fig, style::PlotStyle, groups) -> Legend

The frameless horizontal legend strip above the panels of `fig`, in as many
rows as the figure width requires ([`fit_legend!`](@ref)). `groups` is a
vector of `(title, elements, labels)` tuples, one per series family, drawn
side by side under bold headers; groups without entries are dropped. Every
legend of the project is placed through here.
"""
function figure_legend!(
    fig,
    style::PlotStyle,
    elements::AbstractVector,
    labels::AbstractVector,
)
    legend =
        Legend(fig[0, 1], elements, labels; orientation = :horizontal, tellwidth = false)
    fit_legend!(legend, legend_width(style))
    return legend
end

function figure_legend!(fig, style::PlotStyle, groups::AbstractVector{<:Tuple})
    kept = filter(group -> !isempty(group[2]), groups)
    legend = Legend(
        fig[0, 1],
        [group[2] for group in kept],
        [group[3] for group in kept],
        [group[1] for group in kept];
        orientation = :horizontal,
        titleposition = :top,
        tellwidth = false,
    )
    fit_legend!(legend, legend_width(style))
    return legend
end

# Width a legend may take: the figure less its padding on both sides.
legend_width(style::PlotStyle) =
    style.width - scaled(style, FIGURE_PADDING + FIGURE_PADDING_RIGHT)

"""
    size_to_panels!(fig, rows::Pair{Int,<:Real}...) -> fig

Fixes the axis height of each listed layout row of `fig` (`row => height` in
Makie units, e.g. `1 => style.panel_height`) and resizes the figure to the
height its layout then measures — legend, panels, decorations, gaps, and
padding — at the width it already has. Called last, once the legend and
every axis are in place.
"""
function size_to_panels!(fig, rows::Pair{Int,<:Real}...)
    for (row, height) in rows
        rowsize!(fig.layout, row, Fixed(height))
    end
    resize_to_layout!(fig)
    return fig
end

"""
    save_figure(fig, dir::String, stem::String; formats = ("png", "pdf"), suffix = "") -> String

Saves `fig` as `<dir>/<stem><suffix>.<ext>` for every extension in
`formats` — PNG at `px_per_unit = 4` (≈ 380 dpi at native size), vector
formats at native size — and returns the path of the first one. The figure
is emptied after the last save: Makie keeps the color buffer of a saved
figure, about 70 MiB for a standard PNG, reachable through its scene, so a
caller that still needs the figure draws it again.
"""
function save_figure(
    fig,
    dir::String,
    stem::String;
    formats = ("png", "pdf"),
    suffix::String = "",
)
    mkpath(dir)
    paths = String[]
    for ext in formats
        path = joinpath(dir, stem * suffix * "." * ext)
        ext == "png" ? save(path, fig, px_per_unit = 4) : save(path, fig)
        push!(paths, path)
    end
    empty!(fig)
    return first(paths)
end

"""
    figure_scope(f, style::PlotStyle = PlotStyle())

Runs `f()`, the drawing and saving of one figure, inside a telemetry theme
scope of its own ([`telemetry_theme`](@ref)), runs the garbage collector,
and returns the value of `f`. Makie keeps every figure drawn in a theme
scope reachable until the scope ends, about 70 MiB per standard PNG, so a
scope around a loop accumulates them (a year of daily session figures
exhausted a host); a scope per figure and the release in
[`save_figure`](@ref) bound the loop at one figure. Must not be nested in
another theme scope, which would hold the figures.
"""
function figure_scope(f, style::PlotStyle = PlotStyle())
    result = with_theme(f, telemetry_theme(style))
    GC.gc()
    return result
end

"""
    telemetry_theme(style::PlotStyle = PlotStyle())

The CairoMakie theme of every figure at the scale of `style`: boxed axes with
inward ticks, no titles or minor ticks, a faint dashed grid, guide-weight
rules, stroked markers, and frameless legends with top-aligned bold group
headers. Faces are (New) Computer Modern via MathTeXEngine; current Makie
ignores a plain `font = "Computer Modern"` and falls back to DejaVu. Tick
labels are rotated per axis where they crowd (session HH:MM), not here.
"""
function telemetry_theme(style::PlotStyle = PlotStyle())
    u(length) = scaled(style, length)
    return Theme(
        fonts = (;
            regular = texfont(:text),
            bold = texfont(:bold),
            italic = texfont(:italic),
            bold_italic = texfont(:bolditalic),
        ),
        fontsize = style.fontsize,
        # (left, right, bottom, top)
        figure_padding = (
            u(FIGURE_PADDING),
            u(FIGURE_PADDING_RIGHT),
            u(FIGURE_PADDING),
            u(FIGURE_PADDING),
        ),
        rowgap = u(12),
        colgap = u(12),
        Lines = (linewidth = style.linewidth,),
        Stairs = (linewidth = style.linewidth,),
        VLines = (linewidth = style.linewidth_guide,),
        HLines = (linewidth = style.linewidth_guide,),
        Scatter = (markersize = style.markersize, strokewidth = u(1.5)),
        Legend = (
            framevisible = false,
            backgroundcolor = :transparent,
            labelsize = style.fontsize,
            titlesize = style.fontsize,
            titlefont = :bold,
            gridsvalign = :top,
            patchsize = (u(40), u(22)),
            patchlabelgap = u(8),
            rowgap = u(2),
            colgap = u(28),
            groupgap = u(44),
            titlegap = u(6),
            padding = (0, 0, 0, 0),
            margin = (0, 0, 0, 0),
        ),
        Axis = (
            titlevisible = false,
            spinewidth = u(1.5),
            xgridcolor = (:gray, 0.15),
            ygridcolor = (:gray, 0.15),
            xgridstyle = :dash,
            ygridstyle = :dash,
            xgridwidth = u(1.5),
            ygridwidth = u(1.5),
            xminorticksvisible = false,
            yminorticksvisible = false,
            xtickalign = 1,
            ytickalign = 1,
            xticksize = u(9),
            yticksize = u(9),
            xtickwidth = u(1.5),
            ytickwidth = u(1.5),
            xlabelsize = style.fontsize,
            ylabelsize = style.fontsize,
            xticklabelsize = style.fontsize_tick,
            yticklabelsize = style.fontsize_tick,
            # Clearance of tick labels from the frame and of axis labels
            # from the tick labels.
            xticklabelpad = u(5),
            yticklabelpad = u(6),
            xlabelpadding = u(8),
            ylabelpadding = u(10),
        ),
    )
end

end # module PlotTheme
