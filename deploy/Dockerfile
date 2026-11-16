# The headless simulator in a container image: the channel, instrument and
# queuing models, the post-processing tables and the mission supervisor,
# without the figure stack and without the HDF5 export, so that every Julia
# package in the image is MIT-licensed (headless/test/licences.toml). Build
# from the repository root:
#
#     podman build -f deploy/Dockerfile -t deepspacetelemetry-headless .
#
# Run a scenario; the run directory appears under the volume mounted at /data:
#
#     podman run --rm -v ./data:/data:Z -v ./scenarios:/scenarios:ro,Z \
#         deepspacetelemetry-headless /scenarios/smoke_1d.toml --tick SMOKE
#
# The base image carries its own licences: the Debian userland and the
# libraries of the Julia binary distribution.
FROM docker.io/library/julia:1.13

ENV JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_PKG_PRECOMPILE_AUTO=1 \
    DEEPSPACETELEMETRY_DATA=/data

WORKDIR /opt/deepspacetelemetry
COPY reader reader
COPY headless headless
COPY deploy deploy

# Resolves the environment from the Project.toml files and their [compat]
# bounds, and downloads and precompiles it into the image.
RUN julia deploy/activate.jl && \
    julia -e 'include("deploy/activate.jl"); using DeepSpaceTelemetryHeadless'

# A non-root user; the precompiled depot stays read-only behind a writable one.
RUN useradd --create-home --uid 1000 telemetry && mkdir -p /data && chown telemetry /data
USER telemetry
ENV JULIA_DEPOT_PATH=/home/telemetry/.julia:/opt/julia-depot

VOLUME /data
ENTRYPOINT ["julia", "/opt/deepspacetelemetry/deploy/run_mission.jl"]
