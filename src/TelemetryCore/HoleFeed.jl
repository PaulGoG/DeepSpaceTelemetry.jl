# --- Declared-hole feed ---
"""
    HOLE_FEED_COLUMNS

The columns of `holes.csv`, the declared-hole feed: `DeclaredAt` (the
mission instant the hole was declared at), then the columns of the gap
table, `Cause`, `Batch`, `RowFirst`, `RowLast`, `ContentStart`,
`ContentEnd`.
"""
const HOLE_FEED_COLUMNS =
    (:DeclaredAt, :Cause, :Batch, :RowFirst, :RowLast, :ContentStart, :ContentEnd)

"""
    HoleFeed(run_dir, origin::DateTime, sample_rate::Real, points_per_batch::Integer)

The writer of `<run_dir>/holes.csv`, the declared-hole feed: one row per
hole of the delivered record, appended when its producer declares it. The
receiver declares lost and pruned batches, the emitter scheduled and
recorder gaps, and the supervisor emitter outages; after the mission phase
`Masks.settle_hole_feed!` appends the end-of-run holes, so that the feed of
a finished run and `masks/gaps.csv` hold the same holes. One instance is
shared by the components of a run, and `lock` serializes their appends,
which come from separate threads under the wall clock. The payload grid
(`origin`, `sample_rate`) and `points_per_batch` let a batch name alone fix
its rows. Consumers tail the file directly or through
[`read_hole_feed`](@ref) and `RunAdapter.declared_holes`.
"""
struct HoleFeed
    path::String
    origin::DateTime
    sample_rate::Float64
    points_per_batch::Int
    lock::ReentrantLock
end
HoleFeed(
    run_dir::AbstractString,
    origin::DateTime,
    sample_rate::Real,
    points_per_batch::Integer,
) = HoleFeed(
    joinpath(String(run_dir), "holes.csv"),
    origin,
    Float64(sample_rate),
    Int(points_per_batch),
    ReentrantLock(),
)

"""
    hole_feed(run_dir::String) -> HoleFeed

The feed of a run from its configuration snapshot: `payload_origin(cfg)`,
`physics.sample_rate`, and [`points_per_batch`](@ref).
"""
function hole_feed(run_dir::String)
    cfg = load_run_config(run_dir)
    physics = physics_settings(cfg)
    return HoleFeed(
        run_dir,
        payload_origin(cfg),
        physics.sample_rate,
        points_per_batch(physics),
    )
end

"""
    declare_hole!(feed::HoleFeed, declared_at::DateTime, cause::AbstractString,
                  batch::Union{AbstractString,Missing}, rows::UnitRange{Int}) -> Bool

Appends one row to the feed: `declared_at`, `cause`, `batch` (`missing`
for a generation gap or the unreached tail), the inclusive `rows`, and
the content interval `[payload_row_time(first), payload_row_time(last + 1))`.
Returns `false` and writes nothing when `rows` is empty. The header is
written with the first row.
"""
function declare_hole!(
    feed::HoleFeed,
    declared_at::DateTime,
    cause::AbstractString,
    batch::Union{AbstractString,Missing},
    rows::UnitRange{Int},
)
    isempty(rows) && return false
    df = DataFrame(
        DeclaredAt = DateTime[declared_at],
        Cause = String[String(cause)],
        Batch = Union{Missing,String}[batch === missing ? missing : String(batch)],
        RowFirst = Int[first(rows)],
        RowLast = Int[last(rows)],
        ContentStart = DateTime[payload_row_time(
            feed.origin,
            feed.sample_rate,
            first(rows),
        )],
        ContentEnd = DateTime[payload_row_time(
            feed.origin,
            feed.sample_rate,
            last(rows) + 1,
        )],
    )
    lock(feed.lock) do
        write_table(feed.path, df; append = isfile(feed.path))
    end
    return true
end

"""
    declare_batch_hole!(feed::HoleFeed, declared_at::DateTime, cause::AbstractString, batch_dir::AbstractString) -> Bool

The hole of the batch at `batch_dir` (its name is the batch): rows from
the `payload_row` stamp of its metadata, or from its index when the stamp
is absent, over `points_per_batch` rows; `cause` is `lost` or `pruned`.
"""
function declare_batch_hole!(
    feed::HoleFeed,
    declared_at::DateTime,
    cause::AbstractString,
    batch_dir::AbstractString,
)
    name = basename(batch_dir)
    meta = read_batch_metadata(String(batch_dir))
    first_row = get(meta, "payload_row", nothing)
    first_row isa Integer || (first_row = (batch_id(name) - 1) * feed.points_per_batch + 1)
    return declare_hole!(
        feed,
        declared_at,
        cause,
        name,
        Int(first_row):(Int(first_row)+feed.points_per_batch-1),
    )
end

"""
    declare_gap_hole!(feed::HoleFeed, declared_at::DateTime, cause::AbstractString, start::DateTime, stop::DateTime) -> Bool

The hole of the generation gap `[start, stop)`: rows
`payload_time_row(start) … payload_time_row(stop) − 1`; `cause` is
`scheduled`, `recorder`, or `stream`. Nothing is written for an empty gap.
"""
function declare_gap_hole!(
    feed::HoleFeed,
    declared_at::DateTime,
    cause::AbstractString,
    start::DateTime,
    stop::DateTime,
)
    rows =
        payload_time_row(feed.origin, feed.sample_rate, start):(payload_time_row(
            feed.origin,
            feed.sample_rate,
            stop,
        )-1)
    return declare_hole!(feed, declared_at, cause, missing, rows)
end

"""
    read_hole_feed(run_dir::String; after::Integer = 0) -> DataFrame

The rows of `<run_dir>/holes.csv` beyond the first `after`, typed as
written (`DeclaredAt`, `ContentStart`, `ContentEnd` as `DateTime`); an
empty table with the feed's columns when the file is absent or holds no
further rows.
"""
function read_hole_feed(run_dir::String; after::Integer = 0)
    path = joinpath(run_dir, "holes.csv")
    isfile(path) || return DataFrame(
        DeclaredAt = DateTime[],
        Cause = String[],
        Batch = Union{Missing,String}[],
        RowFirst = Int[],
        RowLast = Int[],
        ContentStart = DateTime[],
        ContentEnd = DateTime[],
    )
    table = read_table(path)
    return after >= DataFrames.nrow(table) ? table[1:0, :] : table[(after+1):end, :]
end

"""
    max_logged_batch_id(run_dir::String) -> Int

Highest batch ID recorded in `events_tx.csv` (0 when the log is absent or
empty) — the authoritative resume point for a re-attaching emitter's batch
counter, immune to batches already delivered out of `onboard/`.
"""
function max_logged_batch_id(run_dir::String)
    path = joinpath(run_dir, "events_tx.csv")
    isfile(path) || return 0
    df = read_table(path)
    isempty(df) && return 0
    return maximum(batch_id(String(b)) for b in df.Batch)
end
