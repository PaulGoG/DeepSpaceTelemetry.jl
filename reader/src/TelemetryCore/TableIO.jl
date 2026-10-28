# --- Backup rotation and table I/O ---
"""
    backup_existing_dir(path::String) -> Union{String, Nothing}

Directory counterpart of [`backup_existing`](@ref): renames an existing
directory to `<name>#<k>` (smallest unused `k`) with a `[SAFESAVE]`
warning, before a same-named arrival takes its place. Returns the backup
path, or `nothing` when `path` did not exist.
"""
function backup_existing_dir(path::String)
    isdir(path) || return nothing
    k = 1
    while ispath("$(path)#$(k)")
        k += 1
    end
    backup = "$(path)#$(k)"
    mv(path, backup)
    @warn "[SAFESAVE] Existing directory backed up to: $backup"
    return backup
end

"""
    backup_existing(path::String) -> Union{String, Nothing}

If `path` exists, renames it to `<name>#<k><ext>` with the smallest unused
`k`: the backup rotation of DrWatson's `safesave`, without the dependency
(the manual's "Provenance conventions" table lists the correspondences).
Returns the backup path, or `nothing` if `path` did not exist.
"""
function backup_existing(path::String)
    isfile(path) || return nothing
    base, ext = splitext(path)
    k = 1
    while isfile("$(base)#$(k)$(ext)")
        k += 1
    end
    backup = "$(base)#$(k)$(ext)"
    mv(path, backup)
    return backup
end

"""
    TIMESTAMP_COLUMNS

Columns of the run-directory tables that hold instants. [`read_table`](@ref)
reads them as `DateTime` whatever the CSV parser would infer, and
[`write_table`](@ref) writes every `DateTime` column in one fixed form.
"""
const TIMESTAMP_COLUMNS = (
    :DeclaredAt,
    :SimTime,
    :WallTime,
    :GenSimTime,
    :ContentEpoch,
    :ContentStart,
    :ContentEnd,
    :AvailableAt,
    :Marker,
)

"""
    timestamp_text(t) -> Union{String,Missing}

The lexical form of an instant in the run-directory tables:
`yyyy-mm-ddTHH:MM:SS.s`, the seconds with at least one and at most three
decimals (`2035-01-04T12:00:36.0`, `2026-09-24T02:01:17.051`). `missing`
stays `missing`.
"""
timestamp_text(t::DateTime) = Dates.format(t, Dates.ISODateTimeFormat)
timestamp_text(::Missing) = missing

"""
    read_table(path::AbstractString; kwargs...) -> DataFrame

Reads a table of the run directory with stated types: the columns of
[`TIMESTAMP_COLUMNS`](@ref) present in its header as `DateTime` (`missing`
where a field is empty) and every text column as `String`; numbers and
booleans are inferred. The inference of the CSV parser is not part of the
file contract: CSV.jl 1.x reads an ISO instant as a nanosecond timestamp
type and text as a string type of its own. `kwargs` are passed to
`CSV.read`.
"""
function read_table(path::AbstractString; kwargs...)
    return CSV.read(
        path,
        DataFrame;
        types = column_types(readline(path)),
        stringtype = String,
        kwargs...,
    )
end

# The stated types of read_table for a header line.
function column_types(header::AbstractString)
    names = Symbol.(strip.(split(header, ',')))
    return Dict{Symbol,Type}(
        name => DateTime for name in names if name in TIMESTAMP_COLUMNS
    )
end

"""
    parse_table(header::AbstractString, body::AbstractVector{UInt8}; kwargs...) -> DataFrame

The rows of `body`, complete CSV lines without a header, under the header
line `header`, typed as [`read_table`](@ref) types a file. `kwargs` are
passed to `CSV.read`.
"""
function parse_table(header::AbstractString, body::AbstractVector{UInt8}; kwargs...)
    text = IOBuffer()
    print(text, header, '\n')
    write(text, body)
    return CSV.read(
        take!(text),
        DataFrame;
        types = column_types(header),
        stringtype = String,
        kwargs...,
    )
end

"""
    write_table(path::AbstractString, table; append = false) -> String

Writes a table of the run directory, every `DateTime` column as text in the
form of [`timestamp_text`](@ref). That form is the one these files have
always carried and is part of the file contract; the default of the CSV
writer is not, and it changed between CSV.jl 0.10 and 1.x.
"""
function write_table(path::AbstractString, table; append::Bool = false)
    source = DataFrame(table; copycols = false)
    out = DataFrame()
    for name in names(source)
        column = source[!, name]
        out[!, name] =
            nonmissingtype(eltype(column)) === DateTime ? timestamp_text.(column) : column
    end
    CSV.write(path, out; append = append)
    return String(path)
end

"""
    safe_csv_write(path::String, table) -> String

Writes `table` to `path` as CSV, first rotating any pre-existing file to a
`#k`-suffixed backup via [`backup_existing`](@ref). Instants are written in
the fixed form of [`timestamp_text`](@ref). Returns `path`.
"""
function safe_csv_write(path::String, table)
    backup = backup_existing(path)
    backup !== nothing && @info "[SAFESAVE] Existing file backed up to: $backup"
    write_table(path, table)
    return path
end
