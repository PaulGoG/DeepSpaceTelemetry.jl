# Log follower for the dashboard terminals: prints a file from its start and
# follows appends; waits for a file that does not exist yet and restarts from
# the beginning when the file is truncated or rotated (retention.log_rotate_mb).
# Pure Julia, so the dashboard carries no shell-utility dependency.
"""
    follow_log(path::AbstractString; poll_sec::Float64 = 0.2)

Streams `path` to `stdout` indefinitely: existing content first, then every
appended byte as it arrives. A missing file is awaited; a shrinking file
(truncation or rotation) is re-read from the start.
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
