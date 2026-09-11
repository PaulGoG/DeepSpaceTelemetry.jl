## What changed

<!-- The change in one or two sentences, and the reason for it. -->

## Verification

<!-- What was run and what it reported: test suite, documentation build,
     scenario runs, benchmarks. Name the configurations and the platform. -->

- [ ] `julia -t 3 --project=. -e 'using Pkg; Pkg.test()'` passes
- [ ] `julia -e 'using JuliaFormatter; format(".")'` leaves the tree unchanged
- [ ] `julia --project=docs docs/make.jl` builds, doctests included
- [ ] `CHANGELOG.md` has an entry under `[Unreleased]` for user-visible changes
- [ ] New behavior comes with a test; new configuration keys are validated,
      documented in every configuration file, and described in the manual

## Open points

<!-- Anything unresolved, deferred, or needing a decision. -->
