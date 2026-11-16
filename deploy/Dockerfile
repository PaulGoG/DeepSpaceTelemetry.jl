# The headless simulator in a container image: the channel, instrument and
# queuing models, the post-processing tables and the mission supervisor,
# without the figure stack and without the HDF5 export, so that every Julia
# package in the image carries a permissive licence
# (headless/test/licences.toml). Build from the repository root:
#
#     podman build -f deploy/Dockerfile -t deepspacetelemetry-headless .
#
# Run a scenario; the run directory appears under the volume mounted at /data:
#
#     mkdir -p data
#     podman run --rm --userns=keep-id:uid=1000,gid=1000 \
#         -v ./data:/data:Z -v ./scenarios:/scenarios:ro,Z \
#         deepspacetelemetry-headless /scenarios/smoke_1d.toml --tick SMOKE
#
# The image runs as uid 1000, which must be able to write to /data: rootless
# Podman needs --userns=keep-id as above, Docker a directory owned by uid
# 1000, a Kubernetes pod runAsUser and fsGroup 1000.
#
# The base image carries its own licences: the Debian userland and the
# libraries of the Julia binary distribution.
FROM docker.io/library/julia:1.13

# Package images for the CPU targets of the official Julia binaries on
# x86-64, so that a node with another processor loads them without
# recompiling; another architecture takes its own list as a build argument.
ARG JULIA_CPU_TARGET="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)"
# The trailing ":" keeps the depot bundled with Julia (its standard
# libraries' caches) behind the image's own.
ENV JULIA_DEPOT_PATH=/opt/julia-depot: \
    JULIA_CPU_TARGET=${JULIA_CPU_TARGET} \
    JULIA_PKG_PRECOMPILE_AUTO=1 \
    DEEPSPACETELEMETRY_DATA=/data

WORKDIR /opt/deepspacetelemetry
COPY reader reader
COPY headless headless
COPY deploy deploy

# Resolves the environment from the Project.toml files and their [compat]
# bounds, downloads and precompiles it into the image, and checks the
# licences of the resolved closure against headless/test/licences.toml.
RUN julia deploy/activate.jl && \
    julia -e 'include("deploy/activate.jl"); using DeepSpaceTelemetryHeadless' && \
    julia -e 'include("deploy/activate.jl"); include("headless/test/licences.jl"); \
        problems = licence_report("deploy/Manifest.toml"); \
        isempty(problems) || error(join(problems, "; "))'

# A non-root user; the precompiled depot stays read-only behind a writable one.
RUN useradd --create-home --uid 1000 telemetry && mkdir -p /data && chown telemetry /data
USER telemetry
ENV JULIA_DEPOT_PATH=/home/telemetry/.julia:/opt/julia-depot:

VOLUME /data
ENTRYPOINT ["julia", "/opt/deepspacetelemetry/deploy/run_mission.jl"]
