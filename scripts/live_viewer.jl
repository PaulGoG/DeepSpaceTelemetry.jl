using Pkg;
Pkg.activate(@__DIR__, io = devnull);
Pkg.instantiate(io = devnull)
using DeepSpaceTelemetry
using UnicodePlots, Dates

"""
    get_batch_info(path::String)

Reads a directory and parses out the Batch IDs for LIVE and ARCH batches.
Returns a tuple of `(live_ids, arch_ids)`.
"""
function get_batch_info(path)
    if !isdir(path)
        return Int[], Int[]
    end
    items = filter(DeepSpaceTelemetry.TelemetryCore.is_batch_name, readdir(path))
    live_ids = Int[]
    arch_ids = Int[]
    for item in items
        id = DeepSpaceTelemetry.TelemetryCore.batch_id(item)
        id == 0 && continue # non-conforming entry
        if DeepSpaceTelemetry.TelemetryCore.is_live_batch(item)
            push!(live_ids, id)
        else
            push!(arch_ids, id)
        end
    end
    return live_ids, arch_ids
end

"""
    run_viewer(run_id::String)

Runs an active terminal UI visualization using UnicodePlots to track the LIFO/FIFO 
progression of telemetry batches across the mission lifecycle.
"""
function run_viewer(run_id::String)
    run_dir = DeepSpaceTelemetry.TelemetryCore.run_directory(run_id)
    onboard_path = joinpath(run_dir, "onboard")
    link_path = joinpath(run_dir, "link")
    ground_path = joinpath(run_dir, "ground")
    lost_path = joinpath(run_dir, "lost")

    print("\e[?25l")
    print("\e[2J")

    # Sliding view window: trail already-grounded batches behind the drain
    # edge, glide toward the target, and hold position (never snap to the end)
    # while the satellite/link are momentarily empty.
    trail_buffer = 15
    glide = 0.25
    view_min = 0.0

    try
        last_state_hash = UInt64(0)
        while true
            if !isdir(run_dir)
                sleep(0.5)
                continue
            end

            onboard_live, onboard_arch = get_batch_info(onboard_path)
            link_live, link_arch = get_batch_info(link_path)
            ground_live, ground_arch = get_batch_info(ground_path)
            lost_live, lost_arch = get_batch_info(lost_path)
            lost_ids = vcat(lost_live, lost_arch)

            current_state_hash = hash((
                onboard_live,
                onboard_arch,
                link_live,
                link_arch,
                ground_live,
                ground_arch,
                lost_ids,
            ))

            if current_state_hash != last_state_hash
                last_state_hash = current_state_hash

                active_ids = vcat(onboard_live, onboard_arch, link_live, link_arch)
                all_ids = vcat(active_ids, ground_live, ground_arch, lost_ids)

                max_id = isempty(all_ids) ? 10 : maximum(all_ids)
                target =
                    isempty(active_ids) ? view_min :
                    Float64(max(0, minimum(active_ids) - trail_buffer))
                view_min += glide * (target - view_min)

                border_w = 80
                plot_w = 70
                plot_h = 9

                output_str =
                    "\e[H\e[J" *
                    "="^border_w *
                    "\n" *
                    lpad("TELEMETRY BATCH TRACKER", 54) *
                    "\n" *
                    "="^border_w *
                    "\n" *
                    " Run ID: $run_id\n" *
                    " Time:   $(Dates.format(now(), "HH:MM:SS"))\n" *
                    "="^border_w *
                    "\n\n"

                print(output_str)

                view_lo = floor(Int, view_min)
                y_lo = isempty(lost_ids) ? 1 : 0
                p = scatterplot(
                    [view_lo, max_id],
                    [y_lo, 3],
                    xlim = (view_lo, max_id+2),
                    ylim = (y_lo, 3),
                    title = "Telemetry batch distribution",
                    xlabel = "Batch ID",
                    ylabel = "",
                    yticks = false,
                    width = plot_w,
                    height = plot_h,
                    color = :black,
                )

                if !isempty(onboard_live)
                    scatterplot!(
                        p,
                        onboard_live,
                        fill(1, length(onboard_live)),
                        color = :red,
                    )
                end
                if !isempty(onboard_arch)
                    scatterplot!(
                        p,
                        onboard_arch,
                        fill(1, length(onboard_arch)),
                        color = :magenta,
                    )
                end

                if !isempty(link_live)
                    scatterplot!(p, link_live, fill(2, length(link_live)), color = :yellow)
                end
                if !isempty(link_arch)
                    scatterplot!(p, link_arch, fill(2, length(link_arch)), color = :blue)
                end

                if !isempty(ground_live)
                    scatterplot!(
                        p,
                        ground_live,
                        fill(3, length(ground_live)),
                        color = :cyan,
                    )
                end
                if !isempty(ground_arch)
                    scatterplot!(
                        p,
                        ground_arch,
                        fill(3, length(ground_arch)),
                        color = :green,
                    )
                end

                if !isempty(lost_ids)
                    scatterplot!(p, lost_ids, fill(0, length(lost_ids)), color = :white)
                end

                show(IOContext(stdout, :color=>true), p)
                println()

                println("\n " * "-"^(border_w-2))
                print("  LIVE: ")
                printstyled("Satellite", color = :red)
                print(" → ")
                printstyled("In-Transit", color = :yellow)
                print(" → ")
                printstyled("Ground Archive", color = :cyan)
                println()
                print("  ARCH: ")
                printstyled("Satellite", color = :magenta)
                print(" → ")
                printstyled("In-Transit", color = :blue)
                print(" → ")
                printstyled("Ground Archive", color = :green)
                println()
                if !isempty(lost_ids)
                    print("  LOST: ")
                    printstyled(
                        "$(length(lost_ids)) batch(es) lost after retry exhaustion (bottom row)",
                        color = :white,
                    )
                    println()
                end
                println(" " * "-"^(border_w-2))
            end

            sleep(0.2)
        end
    catch e
        if isa(e, InterruptException)
            println("\nViewer stopped by user.")
        else
            rethrow(e)
        end
    finally
        print("\e[?25h")
    end
end

if length(ARGS) > 0
    run_viewer(ARGS[1])
else
    latest_run = DeepSpaceTelemetry.TelemetryCore.latest_run_id()
    if latest_run === nothing
        println("No runs found under $(DeepSpaceTelemetry.TelemetryCore.runs_root()).")
    else
        run_viewer(latest_run)
    end
end
