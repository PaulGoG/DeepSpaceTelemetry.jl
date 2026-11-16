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
  dependency closure is MIT-licensed. `headless/test/licences.toml` lists
  them with the licence each one's licence file states, and the tests of the
  headless package fail when a dependency enters the closure without an
  entry there, so a new dependency cannot pass unread.
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
be redistributed. A bundle that must carry permissive licences only is
built from the headless package without the HDF5 extension.

The Julia binary distribution ships libraries of its own under other
licences: the GCC runtime libraries (GPL-3.0 with the GCC Runtime Library
Exception), libgit2 (GPL-2.0 with a linking exception), and the SuiteSparse
modules that `SparseArrays` loads (some GPL-2.0), which the headless package
does not use.

## Installation

From a clone, the headless runner environment `deploy/` uses the two
packages of the checkout:

```bash
julia deploy/run_mission.jl scenarios/smoke_1d.toml --tick SMOKE
```

A project that depends on the headless package adds it by URL. Julia 1.13
resolves the reader through the package's own `[sources]` entry; the Pkg of
Julia 1.12 does not follow the `[sources]` of a dependency, so there both
packages are added in one call:

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
it is set, else `data/` beside the package (`data/` of the clone for the
main package). A container or a cluster job sets the variable to a mounted
volume; `Supervisor.run_mission(cfg; data_root)` overrides both.

## Container image

`deploy/Dockerfile` builds an image of the headless package from the
repository root, with its environment resolved from the `Project.toml`
files and their `[compat]` bounds and precompiled into the image, run by a
non-root user:

```bash
podman build -f deploy/Dockerfile -t deepspacetelemetry-headless .
podman run --rm -v ./data:/data:Z -v ./scenarios:/scenarios:ro,Z \
    deepspacetelemetry-headless /scenarios/smoke_1d.toml --tick SMOKE
```

The image's entry point is `deploy/run_mission.jl`: a configuration path,
`--tick`, and a run ID, as for `scripts/run_full_sim.jl`. Its data root is
the volume mounted at `/data`. In a Kubernetes cluster a mission is a Job
whose pod mounts a persistent volume claim at `/data` and the scenario at a
read-only path, with one run ID per pod (for example the seed of an
ensemble member); the run directory carries its own provenance.

The source identity a run records in the image is that of the `headless/`
directory as copied into it (`identity_source = "directory"`): its git tree
hash equals `git rev-parse <commit>:headless` of the commit the image was
built from. The resolved environment is the run's `manifest_snapshot.toml`.
