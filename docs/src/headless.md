# Headless Package and Containers

The simulator without its figures is a package of its own,
`DeepSpaceTelemetryHeadless`, in the `headless/` directory of the
repository. It holds the channel and instrument models, the emitter and the
receiver on the tick driver, the post-processing tables, the mission
supervisor and sweeps. `DeepSpaceTelemetry` depends on it, re-exports its
modules under the same names, and adds the figures; a mission run through
the headless package alone writes every table and no figure. The reader
package (`reader/`) holds the configuration and run-directory layer that
both use.

## Licences

The code of all three packages is MIT-licensed. Their dependencies differ:

- **Reader and headless package.** Every registered package of their
  dependency closure is under a permissive licence: MIT, apart from
  DataStrings, a dependency of CSV, which is Apache-2.0 with MIT-licensed
  parts and ships a `NOTICE` file. `headless/test/licences.toml` lists them
  with the licences their licence files state. The tests of the headless
  package read those files and fail when a package of the closure is
  missing from the list, states another licence, or is not permissive, so a
  new dependency cannot pass unread.
- **HDF5 export.** It is an extension of the headless package, loaded with
  the HDF5 package. The binaries HDF5 brings (`HDF5_jll`, the MPI libraries
  it links, OpenSSL) are under permissive licences, apart from libiconv
  (LGPL-2.1), which `XML2_jll` links through the MPI library's hardware
  locality layer.
- **Figures.** The main package draws its figures with CairoMakie. Through
  Makie, its closure holds FFmpeg built with GPL and non-free codecs
  (`FFMPEG_jll` with `x264_jll`, `x265_jll` and `libfdk_aac_jll`) and Rmath
  (`Rmath_jll`, GPL-2.0), as well as the LGPL stack of Cairo, Pango and GLib.

Pkg downloads these binaries to the user's depot; the licence of this code
is unaffected. A system image, an application bundle or a container image
that ships them inherits their terms, and the non-free FFmpeg build cannot
be redistributed. A bundle built from the headless package without the
HDF5 extension holds no GPL-licensed or non-free package binary; the
Apache-2.0 terms of DataStrings ask that its `NOTICE` travel with it.

Every bundle also carries the Julia runtime, whose libraries have licences
of their own (`THIRDPARTY.md` of the Julia distribution): GMP (LGPL-3.0 or
GPL-2.0) and MPFR (LGPL-3.0), which every Julia process loads, the GCC
runtime libraries (GPL-3.0 with the GCC Runtime Library Exception), libgit2
(GPL-2.0 with a linking exception), the SuiteSparse modules (several
GPL-2.0 or LGPL-2.1), which the headless package does not load, and the CA
certificates of `MozillaCACerts_jll` (MPL-2.0). A redistributor meets these
terms by passing the licences on and offering the sources. A container
image adds the licences of its base image, the Debian userland of
`julia:1.13`.

## Installation

From a clone, the headless runner environment `deploy/` uses the two
packages of the checkout:

```bash
julia deploy/run_mission.jl scenarios/smoke_1d.toml --tick SMOKE
```

A project that depends on the headless package adds it by URL with the
reader in one call, on every Julia version. Pkg does not follow the
`[sources]` entry `../reader` of a package added by `subdir`: on Julia
1.13.4 the headless package added alone fails to resolve the reader.

```julia
using Pkg
url = "https://github.com/PaulGoG/DeepSpaceTelemetry.jl"
Pkg.add([Pkg.PackageSpec(; url, subdir = "reader"), Pkg.PackageSpec(; url, subdir = "headless")])
```

In a session, `Supervisor.run_mission(cfg; figures = false)` runs a mission;
`Supervisor.figure_backend_loaded()` tells whether the figures of the main
package are available, and `Export.hdf5_available()` whether the HDF5
export is. A configuration that asks for the HDF5 export without the HDF5
package loaded is refused before the run starts.

## Data root

Runs are written under `<data root>/runs/<RUN_ID>`. The data root is the
directory named by the environment variable `DEEPSPACETELEMETRY_DATA` when
it is set, else `data/` under the package directory: `data/` of the clone
for the main package, `headless/data/` for the headless package run from a
clone. A container or a cluster job sets the variable to a mounted volume;
`Supervisor.run_mission(cfg; data_root)` overrides both. A copy installed
by Pkg lies in the depot, where `Pkg.gc` removes a package version with
everything written under it: such a copy warns when a run is created there
and should be given a data root.

A relative `physics.external_data_path` resolves against the package
directory, which for the headless package is `headless/` and in the image
`/opt/deepspacetelemetry/headless`; a relative `contacts.schedule_csv` is
tried against the working directory first. A configuration run in a
container therefore names its inputs by absolute path, under a mounted
volume.

## Container image

`deploy/Dockerfile` builds an image of the headless package from the
repository root, with its environment resolved from the `Project.toml`
files and their `[compat]` bounds and precompiled into the image, run by a
non-root user:

```bash
podman build -f deploy/Dockerfile -t deepspacetelemetry-headless .
mkdir -p data
podman run --rm --userns=keep-id:uid=1000,gid=1000 \
    -v ./data:/data:Z -v ./scenarios:/scenarios:ro,Z \
    deepspacetelemetry-headless /scenarios/smoke_1d.toml --tick SMOKE
```

The image runs as the user `telemetry` (uid 1000), which must be able to
write to the volume at `/data`. Rootless Podman maps the host user to root
in the container; `--userns=keep-id:uid=1000,gid=1000` maps it to the
image's user instead. With Docker, the host directory is made writable by
uid 1000 (`chown 1000 data`); a Kubernetes pod sets `runAsUser: 1000` and
`fsGroup: 1000` in its security context.

The image's entry point is `deploy/run_mission.jl`. It takes a
configuration path, which is required here, and optionally `--tick` and a
run ID, in any order. Its data root is the volume mounted at `/data`. In a
Kubernetes cluster a mission is a Job whose pod mounts a persistent volume
claim at `/data` and the scenario at a read-only path, with one
configuration and one run ID per pod; the members of an ensemble differ in
`simulation.rng_seed`. The run directory carries its own provenance.

A run in the image records the source identity of the `headless/`
directory as copied into it (`identity_source = "directory"`). For an image
built from a clean checkout, its git tree hash equals
`git rev-parse <commit>:headless` of the commit the image was built from,
and `reader_tree_sha1` equals `git rev-parse <commit>:reader`. An untracked
file under `headless/` or `reader/` that `.dockerignore` does not exclude
enters the hash. A run of the headless package in a clone records the
commit itself (`identity_source = "work_tree"`), with `git_dirty` set by
any change to a tracked file of the clone. The resolved environment is the
run's `manifest_snapshot.toml`.

The image compiles its package images for the CPU targets of the official
Julia binaries on x86-64 (`JULIA_CPU_TARGET` in the Dockerfile), so a pod on
another x86-64 processor loads them without recompiling; an image for
another architecture is built with `--build-arg JULIA_CPU_TARGET=...`.
