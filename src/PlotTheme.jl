module PlotTheme

using CairoMakie
using MathTeXEngine: texfont

export telemetry_theme,
    COLOR_LIVE, COLOR_ARCHIVE, COLOR_BANDWIDTH, COLOR_ONBOARD, COLOR_LOST, COLOR_DISRUPTION

# Okabe–Ito colorblind-safe palette (§10): one semantic color per quantity,
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

# --- Journal sizing (§10): design at the final printed width. ---
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

Data-series line width in Makie units (≈ 1.1 pt at final print scale, §10).
"""
const LINEWIDTH_DATA = 1.5

"""
    MARKERSIZE_DATA

Marker size in Makie units for event pins and legend glyphs — one size
everywhere, per the §10 cross-figure consistency rule.
"""
const MARKERSIZE_DATA = 8

"""
    FONTSIZE_ANNOTATION

In-axis annotation font size in Makie units (≈ 7.5 pt at print scale).
"""
const FONTSIZE_ANNOTATION = 10

"""
    telemetry_theme()

Returns a CairoMakie Theme configured for publication-quality telemetry plots
at the final printed width (§10): (New) Computer Modern faces via
MathTeXEngine (a plain `font = "Computer Modern"` string is ignored by
current Makie and silently falls back to DejaVu), ≈ 9 pt body text at
double-column scale, boxed axes with inward ticks, no titles, no minor
ticks, faint dashed grid. Tick-label rotation is applied per axis where
labels actually crowd (session HH:MM axes), not globally.
"""
function telemetry_theme()
    return Theme(
        fonts = (;
            regular = texfont(:text),
            bold = texfont(:bold),
            italic = texfont(:italic),
            bold_italic = texfont(:bolditalic),
        ),
        fontsize = 12,
        figure_padding = 8,
        Lines = (linewidth = LINEWIDTH_DATA,),
        Stairs = (linewidth = LINEWIDTH_DATA,),
        Legend = (
            framevisible = false,
            backgroundcolor = :transparent,
            labelsize = 11,
            patchsize = (20, 10),
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
            xlabelsize = 13,
            ylabelsize = 13,
            xticklabelsize = 11,
            yticklabelsize = 11,
            # Clearance between tick labels and axis labels (§10 spacing
            # discipline).
            xlabelpadding = 8,
            ylabelpadding = 6,
        ),
    )
end

end # module PlotTheme
