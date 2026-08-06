module PlotTheme

using CairoMakie
using MathTeXEngine: texfont

export telemetry_theme,
    COLOR_LIVE, COLOR_ARCHIVE, COLOR_BANDWIDTH, COLOR_ONBOARD, COLOR_LOST, COLOR_DISRUPTION

"""
    COLOR_LIVE

Plot color for near-real-time (Live, FIFO-priority) data batches.
"""
const COLOR_LIVE = :cyan

"""
    COLOR_ARCHIVE

Plot color for blind-spot archive (LIFO-backfilled) data batches.
"""
const COLOR_ARCHIVE = :green

"""
    COLOR_BANDWIDTH

Plot color for the DSN link-capacity (bandwidth) curve.
"""
const COLOR_BANDWIDTH = :blue

"""
    COLOR_ONBOARD

Plot color for the onboard SSD backlog curve.
"""
const COLOR_ONBOARD = :red

"""
    COLOR_LOST

Plot color for permanently lost (retry-exhausted) data batches.
"""
const COLOR_LOST = :firebrick

"""
    COLOR_DISRUPTION

Base color for disruption-event window shading: a neutral dark wash for the
blackout span that fades to zero alpha across the recovery ramp. Deliberately outside the red family, which is reserved for the onboard
buffer curve and lost batches.
"""
const COLOR_DISRUPTION = :black

"""
    telemetry_theme()

Returns a CairoMakie Theme configured for publication-quality telemetry plots.
Uses the (New) Computer Modern faces shipped with MathTeXEngine — a plain
`font = "Computer Modern"` string is ignored by current Makie versions and
silently falls back to DejaVu.
"""
function telemetry_theme()
    return Theme(
        fonts = (;
            regular = texfont(:text),
            bold = texfont(:bold),
            italic = texfont(:italic),
            bold_italic = texfont(:bolditalic),
        ),
        fontsize = 24,
        Lines = (linewidth = 3,),
        Stairs = (linewidth = 3,),
        Legend = (
            framevisible = true,
            framecolor = (:black, 0.7),
            backgroundcolor = (:white, 0.85),
            labelsize = 22,
            patchsize = (36, 18),
        ),
        Axis = (
            titlevisible = false,
            framevisible = true,
            xgridcolor = (:gray, 0.15),
            ygridcolor = (:gray, 0.15),
            xgridstyle = :dash,
            ygridstyle = :dash,
            xminorticksvisible = false,
            yminorticksvisible = false,
            xticklabelrotation = π/4,
            titlesize = 26,
            xlabelsize = 30,
            ylabelsize = 30,
            xticklabelsize = 22,
            yticklabelsize = 22,
            # Breathing room between the tick labels and the axis labels
            # (rotated day/time ticks otherwise crowd "Mission time")
            xlabelpadding = 16,
            ylabelpadding = 12,
        ),
    )
end

end # module PlotTheme
