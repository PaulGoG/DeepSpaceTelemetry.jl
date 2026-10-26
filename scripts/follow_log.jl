# Log follower of the dashboard terminals, so the dashboard needs no shell
# utility. It has no package dependency and does not include activate.jl.
"""
    follow_log(path::AbstractString; poll_sec::Float64 = 0.2)

Streams `path` to `stdout` indefinitely: existing content first, then every
appended byte as it arrives. A missing file is awaited; a shrinking file
(truncation, or rotation under `retention.log_rotate_mb`) is re-read from
the start.
"""
function follow_log(path::AbstractString; poll_sec::Float64 = 0.2)
    offset = 0
    while true
        if !isfile(path)
            offset = 0
            sleep(poll_sec)
            continue
        end
        size = filesize(path)
        size < offset && (offset = 0) # truncated or rotated: start over
        if size > offset
            open(path, "r") do io
                seek(io, offset)
                write(stdout, read(io))
                offset = position(io)
            end
            flush(stdout)
        else
            sleep(poll_sec)
        end
    end
end

if isempty(ARGS)
    println("Usage: julia follow_log.jl <file>")
    exit(1)
end
try
    follow_log(ARGS[1])
catch e
    e isa InterruptException || rethrow()
end
