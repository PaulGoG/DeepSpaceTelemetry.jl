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
    items = filter(f -> startswith(f, "LIVE_") || startswith(f, "ARCH_"), readdir(path))
    live_ids = Int[]
    arch_ids = Int[]
    for item in items
        parts = split(item, "_")
        if length(parts) >= 3
            try
                id = parse(Int, parts[3])
                if startswith(item, "LIVE_")
                    push!(live_ids, id)
                else
                    push!(arch_ids, id)
                end
            catch
            end
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

            onb_l, onb_a = get_batch_info(onboard_path)
            lnk_l, lnk_a = get_batch_info(link_path)
            gnd_l, gnd_a = get_batch_info(ground_path)
            lst_l, lst_a = get_batch_info(lost_path)
            lost_ids = vcat(lst_l, lst_a)

            current_state_hash = hash((onb_l, onb_a, lnk_l, lnk_a, gnd_l, gnd_a, lost_ids))

            if current_state_hash != last_state_hash
                last_state_hash = current_state_hash

                active_ids = vcat(onb_l, onb_a, lnk_l, lnk_a)
                all_ids = vcat(active_ids, gnd_l, gnd_a, lost_ids)

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
                    lpad("TELEMETRY PACKET TRACKER", 54) *
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
                    title = "Telemetry Packet Distribution",
                    xlabel = "Batch ID",
                    ylabel = "",
                    yticks = false,
                    width = plot_w,
                    height = plot_h,
                    color = :black,
                )

                if !isempty(onb_l)
                    scatterplot!(p, onb_l, fill(1, length(onb_l)), color = :red)
                end
                if !isempty(onb_a)
                    scatterplot!(p, onb_a, fill(1, length(onb_a)), color = :magenta)
                end

                if !isempty(lnk_l)
                    scatterplot!(p, lnk_l, fill(2, length(lnk_l)), color = :yellow)
                end
                if !isempty(lnk_a)
                    scatterplot!(p, lnk_a, fill(2, length(lnk_a)), color = :blue)
                end

                if !isempty(gnd_l)
                    scatterplot!(p, gnd_l, fill(3, length(gnd_l)), color = :cyan)
                end
                if !isempty(gnd_a)
                    scatterplot!(p, gnd_a, fill(3, length(gnd_a)), color = :green)
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
                        "$(length(lost_ids)) batch(es) dropped after retry exhaustion (bottom row)",
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
    runs_dir = joinpath(DeepSpaceTelemetry.TelemetryCore.DATA_ROOT[], "runs")
    if isdir(runs_dir)
        runs = filter(x -> startswith(x, "RUN_"), readdir(runs_dir))
        if !isempty(runs)
            latest_run = last(sort(runs, by = x -> mtime(joinpath(runs_dir, x))))
            run_viewer(latest_run)
        else
            println("No runs found.")
        end
    else
        println("Runs directory not found.")
    end
end
