# Contributing

## Environment

- Development requires Julia 1.12 or later, installed with juliaup; I develop
  on Julia 1.13.
- Each environment ships an `activate.jl` that activates and instantiates it
  without output, and each entry-point script includes it as its first
  statement. A new environment gets one, and a new script includes it.
- The test, docs, scripts, and bench environments consume the package by path
  through a `[sources]` entry, so they always run against the local source.
- The repository holds three packages. `reader/` is
  `DeepSpaceTelemetryReader`, holding `TelemetryCore` and `RunAdapter`;
  `headless/` is `DeepSpaceTelemetryHeadless`, the simulator without the
  figure stack, with the HDF5 export as a package extension; the root is
  the main package, which adds the figures. Each depends on the ones
  before it by path and re-exports their modules. The three carry the same
  version number, bumped together at a release with the `[compat]` entries
  on each other.
- A dependency of the headless package or the reader needs an entry in
  `headless/test/licences.toml`, after its licence files have been read:
  the headless suite (`julia headless/test/runtests.jl`) reads them too and
  fails on any package of the closure that the list does not hold, that
  states another licence, or that is not permissive (MIT, Apache-2.0, BSD).
- Manifests are not tracked: `Project.toml` defines an environment, with
  `[compat]` bounds on every dependency, and each CI leg resolves its own. A
  dependency change therefore touches `[deps]` and `[compat]` together.

## Tests and static analysis

- Run `julia test/runtests.jl`. The suite includes the Aqua, JET,
  and ExplicitImports checks and the end-to-end integration missions, and
  takes about four minutes.
- CI runs the suite on Linux for Julia 1.12 (the compat floor), the current
  release, and the prerelease, and on macOS and Windows for the current
  release, and the headless suite on Linux for 1.12 and the current release.
- Every change lands with a green suite; new behavior comes with a test.
  Floating-point comparisons use `isapprox` with explicit tolerances; test
  randomness uses StableRNGs.

## Formatting

- JuliaFormatter belongs to none of the committed environments. Install it
  once into the default environment with
  `julia -e 'using Pkg; Pkg.add(name = "JuliaFormatter", version = "2.14.12")'`
  and format from the package root with
  `julia -e 'using JuliaFormatter; format(".")'`, which reads the committed
  `.JuliaFormatter.toml`. The `Format` workflow runs the same version on
  every push and pull request and fails on unformatted files.

## Documentation

- `julia docs/make.jl` builds the manual from `docs/src/` into `docs/build/`.
  Public functions and structs carry docstrings.
- The CI docs job deploys the manual to GitHub Pages: `stable` from version
  tags and `dev` from `main`, so a docs change is visible under the version
  selector's `dev` entry after the push. The README links the stable manual
  only.
- Docstring examples are `jldoctest` blocks executed by the docs build; a
  changed output fails the build, so the example is updated with the
  behavior.
- The figures of the manual and of the README are run products.
  `julia docs/render_assets.jl` runs the gallery scenarios one after another
  on the tick clock, reduces the figures with ImageMagick, and rewrites
  `docs/src/assets/PROVENANCE.toml`. The figures are regenerated when a
  change alters a figure or the regime a shipped scenario reaches, under a
  new run-ID prefix or after purging the earlier runs.

## Configuration changes

- A new key gets a checked coercion and bounds in `TelemetryCore`, with a
  precise `[CONFIG]` error naming the key. Wherever it appears in
  `config.toml` or under `scenarios/` it carries a one-line comment (what it
  is, its allowed values or bounds, its units), and `docs/src/usage.md`
  mentions it.
- Configuration comments carry no scenario rationale; that belongs in the
  manual.

## Commits and pull requests

- Commits follow Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`,
  `test:`, `perf:`, `chore:`), one logical change per commit, with a body
  stating what changed and why.
- Commit messages and pull-request descriptions contain no attribution
  trailers, generated footers, or tool identifiers.
- User-visible changes get an entry under `[Unreleased]` in `CHANGELOG.md`.
- A change to the public surface (the run-directory contract, the
  configuration schema, the scripts' arguments and products, the public
  names of `RunAdapter`) is marked **Breaking** in the changelog and waits
  for a major release. A change to the other modules and functions is not
  breaking by itself.
- A pull-request description states the change, how it was verified (suite, docs
  build, runs), and any open points.

## Register

- Identifiers, comments, documentation, and messages use standard scientific
  and engineering terminology without colloquialisms; labels and messages are
  in sentence case.
