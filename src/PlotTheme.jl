"""
    PlotTheme

Plotting standards shared by every figure: the Okabe–Ito semantic palette,
the standard figure layout with its uniform print scaling
([`PlotStyle`](@ref)), the measured legend and figure sizing
([`figure_legend!`](@ref), [`size_to_panels!`](@ref)), and the CairoMakie
theme ([`telemetry_theme`](@ref)).
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
    save
using MathTeXEngine: texfont

# Okabe–Ito colorblind-safe palette: one semantic color per quantity,
# consistent across every figure and the animation.

"""
    COLOR_LIVE

Plot color for near-real-time (Live, FIFO-priority) data batches
(Okabe–Ito sky blue).
"""
const COLOR_LIVE = colorant"#56B4E9"

"""
    COLOR_ARCHIVE

Plot color for blind-spot archive (LIFO-backfilled) data batches
(Okabe–Ito bluish green).
"""
const COLOR_ARCHIVE = colorant"#009E73"

"""
    COLOR_BANDWIDTH

Plot color for the DSN link-capacity (bandwidth) curve (Okabe–Ito blue).
"""
const COLOR_BANDWIDTH = colorant"#0072B2"

"""
    COLOR_ONBOARD

Plot color for the onboard SSD backlog curve (Okabe–Ito orange; role is
additionally encoded by the dashed line style, so the figure survives
grayscale).
"""
const COLOR_ONBOARD = colorant"#E69F00"

"""
    COLOR_LOST

Plot color for permanently lost (retry-exhausted) data batches (Okabe–Ito
vermillion; role additionally encoded by ✕ markers).
"""
const COLOR_LOST = colorant"#D55E00"

"""
    COLOR_COUNTERFACTUAL

Plot color for counterfactual quantities — the first-in, first-out drain
the alert-latency figure contrasts with the realized doctrine (Okabe–Ito
reddish purple; role additionally encoded by the dotted line style).
"""
const COLOR_COUNTERFACTUAL = colorant"#CC79A7"

"""
    COLOR_DISRUPTION

Base color for disruption-event window shading: a neutral dark wash for the
blackout span that fades to zero alpha across the recovery ramp, with dashed
same-hue edge lines at higher alpha. Deliberately neutral so it never
competes with the series palette.
"""
const COLOR_DISRUPTION = :black

"""
    COLOR_OUTAGE

Base color for component-outage window shading: a neutral wash at low alpha
with dotted same-hue edge lines at higher alpha, so unscheduled
infrastructure outages stay apart from the series palette and, by line
style, from the dashed disruption shading.
"""
const COLOR_OUTAGE = :black

"""
    COLOR_MARKER

Plot color for the per-event-marker realized latency curves of the
alert-latency figure — a family apart from the population bands, its
members told apart by cycling line styles.
"""
const COLOR_MARKER = :black

"""
    COLOR_GUIDE

Neutral grey for population aggregates and reference guides: the
all-batches delivery curve, the delivery-requirement line, and its label.
"""
const COLOR_GUIDE = colorant"gray40"

"""
    COLOR_FUTURE

Wash of the not-yet-generated region of the batch-state raster: a near-white
that reads as absence rather than as one more state, so the generation front
appears as the boundary of the drawn area.
"""
const COLOR_FUTURE = colorant"#F5F5F5"

# --- Standard layout ---
# Every figure is composed once, at the standard layout below, and scaled as
# a whole: `PlotStyle(scale)` multiplies every length by the same factor, so
# a figure printed narrower is a miniature of the standard one and no two of
# its elements can newly meet. Makie layout units are 1/96 inch; a vector
# export enters LaTeX at native size.

"""
    FIGURE_WIDTH

Width of every figure at the standard layout, in Makie units. The figures of
a mission are stacked time-series dashboards with one shared width, so
sibling figures print with identical type.
"""
const FIGURE_WIDTH = 1200

"""
    PANEL_HEIGHT

Axis height of a main panel at the standard layout, in Makie units.
"""
const PANEL_HEIGHT = 380

"""
    STRIP_HEIGHT

Axis height of an auxiliary strip (the Lost strip of the mission summary) at
the standard layout, in Makie units.
"""
const STRIP_HEIGHT = 150

"""
    FONTSIZE

Font size of axis labels, legends, and legend headers at the standard
layout, in Makie units.
"""
const FONTSIZE = 26

"""
    FONTSIZE_TICK

Tick-label font size at the standard layout, in Makie units.
"""
const FONTSIZE_TICK = 22

"""
    FONTSIZE_ANNOTATION

In-axis annotation font size at the standard layout, in Makie units.
"""
const FONTSIZE_ANNOTATION = 21

"""
    LINEWIDTH_DATA

Data-series line width at the standard layout, in Makie units.
"""
const LINEWIDTH_DATA = 3.0

"""
    LINEWIDTH_GUIDE

Line width of reference and guide lines — thresholds, requirement rules,
the edges of shaded event windows, event-marker rules — at the standard
layout, in Makie units.
"""
const LINEWIDTH_GUIDE = 1.5

"""
    LINEWIDTH_EDGE

Line width of the same-hue edge drawn on an area fill at the standard
layout, in Makie units.
"""
const LINEWIDTH_EDGE = 2.5

"""
    MARKERSIZE_DATA

Marker size of event pins and legend glyphs at the standard layout, in Makie
units — one size everywhere, so every figure of the project draws it
identically.
"""
const MARKERSIZE_DATA = 14

"""
    FILL_ALPHA

Alpha of the area fills under cumulative curves; the fill carries a full-hue
edge of [`LINEWIDTH_EDGE`](@ref).
"""
const FILL_ALPHA = 0.35

"""
    FIGURE_PADDING

Outer padding of every figure at the standard layout, in Makie units.
"""
const FIGURE_PADDING = 10

"""
    FIGURE_PADDING_RIGHT

Right-hand padding of every figure at the standard layout, in Makie units:
the outer padding plus half the width of a tick label, which an x tick
landing on the axis frame pushes past it.
"""
const FIGURE_PADDING_RIGHT = 45

"""
    AXIS_WIDTH_SHARE

Share of the figure width a stacked panel's axis occupies once the y-axis
decorations of both sides and the padding are taken out. An estimate, used
only to express the width of an annotation relative to its axis
([`annotation_fraction`](@ref)).
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

Which end of an axis an in-axis annotation block should occupy: `:right`
unless one of the `occupied` x positions — the upright rules and shaded
edges a figure draws — falls within `fraction` of the axis width of the
right edge, in which case `:left`. `fraction` is the block's own width
relative to the axis ([`annotation_fraction`](@ref)), so the test asks
whether a rule would cross the text. When both ends are occupied it stays
`:right`, since moving buys nothing.
"""
function annotation_side(occupied, x_lo::Real, x_hi::Real, fraction::Real)
    span = x_hi - x_lo
    span > 0 || return :right
    in_right = any(x -> (x - x_lo) / span > 1 - fraction, occupied)
    in_left = any(x -> (x - x_lo) / span < fraction, occupied)
    return in_right && !in_left ? :left : :right
end

"""
    TICK_PRUNE_FRACTION

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
formats at native size — and returns the path of the first one.
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
    return first(paths)
end

"""
    telemetry_theme(style::PlotStyle = PlotStyle())

The CairoMakie theme of every figure at the scale of `style`: (New) Computer
Modern faces via MathTeXEngine (a plain `font = "Computer Modern"` string is
ignored by current Makie and silently falls back to DejaVu), boxed axes with
inward ticks, no titles, no minor ticks, a faint dashed grid, guide-weight
upright and level rules, stroked markers, and frameless horizontal legends
with bold group headers aligned at the top. Tick-label rotation is applied
per axis where labels actually crowd (session HH:MM axes), not globally.
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
            # from the tick labels (spacing discipline).
            xticklabelpad = u(5),
            yticklabelpad = u(6),
            xlabelpadding = u(8),
            ylabelpadding = u(10),
        ),
    )
end

end # module PlotTheme
