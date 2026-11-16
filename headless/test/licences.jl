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

# The licences the licence files at the top of `root` state, joined with "+"
# in sorted order ("UNKNOWN" for a file this does not recognize, "NONE"
# without a licence file). Whitespace runs read as one space, so a phrase
# broken across lines is found.
function licence_of_directory(root::AbstractString)
    files = filter(f -> occursin(r"^(licen[cs]e|copying)"i, f), readdir(root))
    kinds = String[]
    for f in files
        text = lowercase(replace(read(joinpath(root, f), String), r"\s+" => " "))
        found = [kind for (kind, phrase) in LICENCE_PHRASES if occursin(phrase, text)]
        append!(kinds, isempty(found) ? ["UNKNOWN"] : found)
    end
    return isempty(kinds) ? "NONE" : join(sort!(unique(kinds)), "+")
end

# The licences of an installed package of the active environment.
licence_of(name::AbstractString, uuid::Base.UUID) =
    licence_of_directory(dirname(dirname(Base.locate_package(Base.PkgId(uuid, name)))))

# What is wrong with one package of the closure: `found` is what its licence
# files state, `listed` and `binaries` the tables of the list. A binary
# package (`_jll`) also needs the licence of its artifact under
# `[binaries]`, read from the artifact's `share/licenses`, since its own
# licence file covers the wrapper only.
function package_problems(name::AbstractString, found::AbstractString, listed, binaries)
    problems = String[]
    permissive(kinds) = all(in(PERMISSIVE), split(kinds, "+"))
    if endswith(name, "_jll")
        binary = get(binaries, name, nothing)
        if binary === nothing
            push!(problems, "$name is a binary package without its artifact's licence")
        elseif !permissive(binary)
            push!(problems, "$name carries a $binary binary, which is not permissive")
        end
    end
    expected = get(listed, name, nothing)
    if expected === nothing
        push!(problems, "$name is not listed (its licence files state $found)")
    elseif found != expected
        push!(problems, "$name is listed as $expected, its licence files state $found")
    elseif !permissive(found)
        push!(problems, "$name carries $found, which is not permissive")
    end
    return problems
end

# The problems of every registered package of the closure (empty when every
# one passes): unlisted, stated otherwise than listed, or not permissive.
function licence_report(
    manifest_path::AbstractString,
    list_path::AbstractString = joinpath(@__DIR__, "licences.toml"),
)
    list = TOML.parsefile(list_path)
    listed = list["packages"]
    binaries = get(list, "binaries", Dict{String,Any}())
    problems = String[]
    for (name, uuid) in registered_closure(manifest_path)
        append!(problems, package_problems(name, licence_of(name, uuid), listed, binaries))
    end
    return problems
end
