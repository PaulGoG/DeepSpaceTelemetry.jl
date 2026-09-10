# Contributing

This guide records the working conventions of the repository.

## Environment

- Development requires Julia 1.12 or later, installed with juliaup; Julia 1.13
  is the development version.
- Every entry-point script activates and instantiates its own environment
  silently; the one-time explicit instantiation is
  `julia --project=. -e 'using Pkg; Pkg.instantiate()'` from the package root.
- The test, docs, scripts, and bench environments consume the package by path
  through a `[sources]` entry, so they always run against the local source.
- After any change to a `Project.toml`, re-resolve all five Manifests (root,
  test, docs, scripts, bench) with `Pkg.resolve()` in each environment and
  commit them; the committed Manifests are the portability guarantee.

## Tests and static analysis

- Run `julia -t 3 --project=. -e 'using Pkg; Pkg.test()'`; the suite includes
  Aqua, JET, and ExplicitImports checks and four integration missions and takes
  about four minutes.
- Every change lands with a green suite; new behaviour comes with a test.
  Floating-point comparisons use `isapprox` with explicit tolerances; test
  randomness uses StableRNGs.

## Formatting

- JuliaFormatter runs against the committed `.JuliaFormatter.toml` via
  `julia -e 'using JuliaFormatter; format(".")'` from the package root; the CI
  formatting job fails on unformatted files.

## Documentation

- `julia docs/make.jl` builds the manual into `docs/build/`; every public
  function and struct carries a docstring; the manual pages live under
  `docs/src/`.
- Deployment to GitHub Pages is added when the repository becomes public; until
  then the CI docs job only builds.

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
- A pull-request description states the change, how it was verified (suite, docs
  build, runs), and any open points.

## Register

- Identifiers, comments, documentation, and messages use standard scientific and
  engineering terminology in sentence case; no colloquialisms are permitted.
