# The licence check of the dependency closure, shared by the tests of the
# headless package (runtests.jl) and the image build (deploy/Dockerfile).
# Run with the environment of `manifest_path` active, so that the packages
# can be located.
using TOML: TOML

# Licences a package of the closure may carry.
const PERMISSIVE = ("MIT", "Apache-2.0", "BSD")

# The registered packages of a resolved closure (the entries with a tree
# hash, upgraded standard libraries included), with their UUIDs.
function registered_closure(manifest_path::AbstractString)
    deps = TOML.parsefile(manifest_path)["deps"]
    return sort!([
        (name, Base.UUID(entries[1]["uuid"])) for
        (name, entries) in deps if haskey(entries[1], "git-tree-sha1")
    ])
end

# Phrases that identify a licence in a licence file. Every phrase a file
# holds counts, so a text that names a copyleft licence beside a permissive
# one is not read as permissive.
const LICENCE_PHRASES = (
    "Apache-2.0" => "apache license",
    "GPL" => "general public license",
    "MPL-2.0" => "mozilla public license",
    "MIT" => "permission is hereby granted, free of charge",
    "BSD" => "redistribution and use in source and binary forms",
)

# The licences the top-level licence files of an installed package state,
# joined with "+" in sorted order ("UNKNOWN" for a file this does not
# recognize, "NONE" without a licence file).
function licence_of(name::AbstractString, uuid::Base.UUID)
    root = dirname(dirname(Base.locate_package(Base.PkgId(uuid, name))))
    files = filter(f -> occursin(r"^(licen[cs]e|copying)"i, f), readdir(root))
    kinds = String[]
    for f in files
        text = lowercase(read(joinpath(root, f), String))
        found = [kind for (kind, phrase) in LICENCE_PHRASES if occursin(phrase, text)]
        append!(kinds, isempty(found) ? ["UNKNOWN"] : found)
    end
    return isempty(kinds) ? "NONE" : join(sort!(unique(kinds)), "+")
end

# The packages of the closure that the list lacks, whose licence files state
# something else than the list, or whose licence is not permissive; empty
# when every package passes. A binary package (`_jll`) also needs the
# licence of its artifact under `[binaries]`, read from the artifact's
# `share/licenses`, since its own licence file covers the wrapper only.
function licence_report(
    manifest_path::AbstractString,
    list_path::AbstractString = joinpath(@__DIR__, "licences.toml"),
)
    list = TOML.parsefile(list_path)
    listed = list["packages"]
    binaries = get(list, "binaries", Dict{String,Any}())
    problems = String[]
    for (name, uuid) in registered_closure(manifest_path)
        if endswith(name, "_jll")
            binary = get(binaries, name, nothing)
            binary === nothing &&
                push!(problems, "$name is a binary package without its artifact's licence")
            binary === nothing ||
                all(in(PERMISSIVE), split(binary, "+")) ||
                push!(problems, "$name carries a $binary binary, which is not permissive")
        end
        found = licence_of(name, uuid)
        expected = get(listed, name, nothing)
        if expected === nothing
            push!(problems, "$name is not listed (its licence files state $found)")
        elseif found != expected
            push!(problems, "$name is listed as $expected, its licence files state $found")
        elseif !all(in(PERMISSIVE), split(found, "+"))
            push!(problems, "$name carries $found, which is not permissive")
        end
    end
    return problems
end
