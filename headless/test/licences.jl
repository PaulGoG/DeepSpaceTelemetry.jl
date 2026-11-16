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

# The licences the licence files of an installed package state, joined with
# "+" in sorted order ("UNKNOWN" for a text this does not recognize).
function licence_of(name::AbstractString, uuid::Base.UUID)
    root = dirname(dirname(Base.locate_package(Base.PkgId(uuid, name))))
    files = filter(f -> occursin(r"^(licen[cs]e|copying)"i, f), readdir(root))
    kinds = map(files) do f
        text = lowercase(read(joinpath(root, f), String))
        occursin("apache license", text) ? "Apache-2.0" :
        occursin("general public license", text) ? "GPL" :
        occursin("mozilla public license", text) ? "MPL-2.0" :
        occursin("permission is hereby granted, free of charge", text) ? "MIT" :
        occursin("redistribution and use in source and binary forms", text) ? "BSD" :
        "UNKNOWN"
    end
    return isempty(kinds) ? "NONE" : join(sort!(unique(kinds)), "+")
end

# The packages of the closure that the list lacks, whose licence files state
# something else than the list, or whose licence is not permissive; empty
# when every package passes.
function licence_report(
    manifest_path::AbstractString,
    list_path::AbstractString = joinpath(@__DIR__, "licences.toml"),
)
    listed = TOML.parsefile(list_path)["packages"]
    problems = String[]
    for (name, uuid) in registered_closure(manifest_path)
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
