# Contributing

## Environment

- Development requires Julia 1.12 or later, installed with juliaup; Julia 1.13
  is the development version.
- Each environment ships an `activate.jl` that activates and instantiates it
  without output. Every entry-point script includes it as its first
  statement, so `--project` is never passed; `julia -i test/activate.jl`
  leaves a REPL in the test environment. A new environment gets one, and a
  new script includes it.
- The test, docs, scripts, and bench environments consume the package by path
  through a `[sources]` entry, so they always run against the local source.
- Manifests are not tracked. `Project.toml` with `[compat]` bounds on every
  dependency defines an environment, every CI leg resolves its own, and each
  run stores the manifest it was resolved on as `manifest_snapshot.toml` in
  its run directory. A dependency change therefore touches `[deps]` and
  `[compat]` together.

## Tests and static analysis

- Run `julia --threads=3 test/runtests.jl`; the suite
  includes Aqua, JET, and ExplicitImports checks and four integration missions
  and takes about four minutes.
- CI runs the suite on Linux for Julia 1.12 (the compat floor), the current
  release, and the prerelease, and on macOS and Windows for the current
  release.
- Every change lands with a green suite; new behavior comes with a test.
  Floating-point comparisons use `isapprox` with explicit tolerances; test
  randomness uses StableRNGs.

## Formatting

- JuliaFormatter is in none of the committed environments; it is installed
  once into the default environment with
  `julia -e 'using Pkg; Pkg.add("JuliaFormatter")'`. The format command,
  `julia -e 'using JuliaFormatter; format(".")'`, runs from the package root
  against the committed `.JuliaFormatter.toml`; the CI formatting job fails on
  unformatted files.

## Documentation

- `julia docs/make.jl` builds the manual into `docs/build/`; every public
  function and struct carries a docstring; the manual pages live under
  `docs/src/`.
- The CI docs job deploys the manual to GitHub Pages: `stable` from version
  tags and `dev` from `main`, so a docs change is visible under the version
  selector's `dev` entry after the push. The README links the stable manual
  only.
- Docstring examples are `jldoctest` blocks executed by the docs build; a
  changed output fails the build, so the example is updated with the
  behavior.

## Configuration changes

- A new key gets a checked coercion and bounds in `TelemetryCore` with a precise
  `[CONFIG]` error naming the key, a one-line comment in `config.toml` and in every file under `scenarios/`
  stating what it is, its allowed values or bounds, and its units, and a mention in
  `docs/src/usage.md`.
- Configuration comments carry no scenario rationale; that belongs in the
  manual.

## Commits and pull requests

- Commits follow Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`,
  `test:`, `perf:`, `chore:`), one logical change per commit, with a body
  stating what changed and why.
- Commit messages and pull-request descriptions contain no attribution
  trailers, generated footers, or tool identifiers.
- User-visible changes get an entry under `[Unreleased]` in `CHANGELOG.md`.
- A change to the public surface — the run-directory contract, the
  configuration schema, the scripts' arguments and products — is marked
  **Breaking** in the changelog and waits for a major release; a change to
  the modules and functions is not breaking by itself.
- A pull-request description states the change, how it was verified (suite, docs
  build, runs), and any open points.

## Register

- Identifiers, comments, documentation, and messages use standard scientific and
  engineering terminology in sentence case; no colloquialisms are permitted.
