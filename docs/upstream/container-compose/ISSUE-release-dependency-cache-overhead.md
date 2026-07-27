# Current packaging spends most of its build window restoring dependency caches

## Problem

Exact-main Current packaging run
[`30235634675`](https://github.com/stephenlclarke/container-compose/actions/runs/30235634675)
spent 10 minutes restoring a 2,134,173,923-byte SwiftPM cache before a
2-minute-25-second matched-runtime build. Its `setup-go` step then spent
19 minutes 19 seconds downloading a 1,624,881,811-byte cache, failed
authentication after receiving about 1.29 GB, and built the Compose archive in
2 minutes 17 seconds without that restored cache.

The package job took 43 minutes. More than two thirds of the pre-publication
window was cache transfer that did not establish release authority or improve
the observed build enough to recover its cost.

## Expected behavior

- Build the exact matched Container and Compose packages from their immutable
  clean checkouts.
- Do not download or upload multi-gigabyte SwiftPM build trees in the release
  job.
- Install the pinned Go toolchain without restoring or saving the machine-wide
  module/build cache.
- Retain caching in validation workflows where repeated compilation can
  amortize it; this correction is limited to package publication.

## Ownership and boundary

This is Compose release orchestration on the designated macOS runner. It
changes no Apple source, package contents, runtime API, Docker Compose
semantics, Windows path, or typed/live VHS behavior.

## Resolution

Signed commit `6cae9a84deee2b13eecfeb1efbf83ad2c98f88a9`
(`perf(release): avoid oversized dependency caches`) removes the release-only
SwiftPM cache action and sets `setup-go` to `cache: false`.

## Acceptance

- Workflow policy tests require the SwiftPM cache step and fingerprint to
  remain absent.
- Workflow policy tests require the release `setup-go` step to disable caching
  and omit a dependency-cache path.
- YAML parsing, actionlint, the complete release test suite, full CI,
  SonarCloud, and Current publication pass.
- The next exact-main Package job records the cache-free step timings for
  comparison with run `30235634675`.
