"""
    PlotTheme

Publication plotting standards shared by every figure: the Okabe–Ito
semantic palette, journal-width figure geometry, print-scale typography, and
the CairoMakie theme ([`telemetry_theme`](@ref)).
"""
module PlotTheme

using CairoMakie: CairoMakie, @colorant_str, Theme, save
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
    COLOR_DISRUPTION

Base color for disruption-event window shading: a neutral dark wash for the
blackout span that fades to zero alpha across the recovery ramp. Deliberately
neutral so it never competes with the series palette.
"""
const COLOR_DISRUPTION = :black

# --- Journal sizing: design at the final printed width. ---
# Makie layout units are 1/96 inch; a PDF exported at these sizes enters
# LaTeX at native scale (178 mm double-column ≈ 673 units), and PNG at
# px_per_unit = 4 renders ≥ 380 dpi.

"""
    FIG_SIZE_SUMMARY

Mission-summary figure size in Makie units: 178 mm double-column width at the
final printed scale (three stacked panels + legend strip).
"""
const FIG_SIZE_SUMMARY = (673, 500)

"""
    FIG_SIZE_SESSION

Session-detail figure size in Makie units: 178 mm double-column width
(two stacked panels + legend strip).
"""
const FIG_SIZE_SESSION = (673, 420)

"""
    LINEWIDTH_DATA

Data-series line width in Makie units (≈ 1.1 pt at final print scale).
"""
const LINEWIDTH_DATA = 1.5

"""
    MARKERSIZE_DATA

Marker size in Makie units for event pins and legend glyphs — one size
everywhere, so every figure of the project draws it identically.
"""
const MARKERSIZE_DATA = 8

"""
    FONTSIZE_ANNOTATION

In-axis annotation font size in Makie units (≈ 7.5 pt at print scale).
"""
const FONTSIZE_ANNOTATION = 10

"""
    PlotStyle

Print-scale parameters of one figure set: `scale` relative to the
double-column design width (178 mm ↔ 673 Makie units), the derived figure
sizes, line width, marker size, and the font sizes (body, axis label, tick
label, legend, in-axis annotation). Fonts and strokes do not shrink
linearly with the width — `PlotStyle(scale)` floors them so text stays
≥ 7 pt at the final print size — and narrow figures gain height for the
legends that wrap.
"""
struct PlotStyle
    scale::Float64
    size_summary::Tuple{Int,Int}
    size_session::Tuple{Int,Int}
    linewidth::Float64
    markersize::Float64
    fontsize::Float64
    fontsize_label::Float64
    fontsize_tick::Float64
    fontsize_legend::Float64
    fontsize_annotation::Float64
end

function PlotStyle(scale::Real = 1.0)
    scale > 0 || throw(ArgumentError("PlotStyle scale must be > 0 (got $scale)."))
    s = Float64(scale)
    text = max(s, 0.85)          # ≈ 7 pt floor at print size
    height = s < 1 ? s * (1 + 1.0 * (1 - s)) : s
    return PlotStyle(
        s,
        (round(Int, FIG_SIZE_SUMMARY[1] * s), round(Int, FIG_SIZE_SUMMARY[2] * height)),
        (round(Int, FIG_SIZE_SESSION[1] * s), round(Int, FIG_SIZE_SESSION[2] * height)),
        LINEWIDTH_DATA * max(s, 0.7),
        MARKERSIZE_DATA * max(s, 0.75),
        12 * text,
        13 * text,
        11 * text,
        11 * text,
        max(FONTSIZE_ANNOTATION * text, 9.4),
    )
end

"""
    label(style::PlotStyle, long::String, short::String) -> String

`long` at the design width, `short` for narrow figures (`scale < 0.7`),
where a long axis label would collide with the neighbouring panel.
"""
label(style::PlotStyle, long::String, short::String) = style.scale < 0.7 ? short : long

"""
    style_for_width(column_width_mm::Real) -> PlotStyle

The [`PlotStyle`](@ref) of a figure printed `column_width_mm` wide (Makie
units are 1/96 inch; 178 mm is the design width, scale 1).
"""
style_for_width(column_width_mm::Real) =
    PlotStyle(column_width_mm / 25.4 * 96 / FIG_SIZE_SUMMARY[1])

"""
    save_figure(fig, dir::String, stem::String; formats = ("png", "pdf"), suffix = "") -> String

Saves `fig` as `<dir>/<stem><suffix>.<ext>` for every extension in
`formats` — PNG at `px_per_unit = 4` (≥ 380 dpi at print size), vector
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

Returns a CairoMakie Theme configured for publication-quality telemetry plots
at the final printed width: (New) Computer Modern faces via
MathTeXEngine (a plain `font = "Computer Modern"` string is ignored by
current Makie and silently falls back to DejaVu), ≈ 9 pt body text at
double-column scale (floored at ≈ 7 pt for narrower `style`s), boxed axes
with inward ticks, no titles, no minor ticks, faint dashed grid.
Tick-label rotation is applied per axis where labels actually crowd
(session HH:MM axes), not globally.
"""
function telemetry_theme(style::PlotStyle = PlotStyle())
    patch = max(style.scale, 0.75)
    return Theme(
        fonts = (;
            regular = texfont(:text),
            bold = texfont(:bold),
            italic = texfont(:italic),
            bold_italic = texfont(:bolditalic),
        ),
        fontsize = style.fontsize,
        figure_padding = 8,
        Lines = (linewidth = style.linewidth,),
        Stairs = (linewidth = style.linewidth,),
        Legend = (
            framevisible = false,
            backgroundcolor = :transparent,
            labelsize = style.fontsize_legend,
            patchsize = (20 * patch, 10 * patch),
        ),
        Axis = (
            titlevisible = false,
            xgridcolor = (:gray, 0.15),
            ygridcolor = (:gray, 0.15),
            xgridstyle = :dash,
            ygridstyle = :dash,
            xminorticksvisible = false,
            yminorticksvisible = false,
            xtickalign = 1,
            ytickalign = 1,
            xlabelsize = style.fontsize_label,
            ylabelsize = style.fontsize_label,
            xticklabelsize = style.fontsize_tick,
            yticklabelsize = style.fontsize_tick,
            # Clearance between tick labels and axis labels (spacing
            # discipline).
            xlabelpadding = 8,
            ylabelpadding = 6,
        ),
    )
end

end # module PlotTheme
