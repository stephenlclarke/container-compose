# Refresh the matched Container pin for Apple's builder race fix

## Context

Apple `container` merged apple/container#2002 after the Phase 4 Current
candidate had been published. The strict stable-release divergence gate found
the new upstream commit and stopped the `0.9.0` promotion.

Apple issue #2001 demonstrates that concurrent cold-start builds can both
decide the shared BuildKit container is absent. The losing create call then
returns `ContainerizationError.exists`, causing an otherwise valid build to
fail even though the winning build created the required builder.

## Required behavior

- Synchronize the Container fork with Apple commit `d1d76353`.
- Preserve the fork's named builders, SSH forwarding, lifecycle events, and
  exact runtime provenance.
- Pin Compose to the signed, documented Container head.
- Rebuild and retest the complete matched graph before replacing Current or
  publishing stable `0.9.0`.
- Keep the README fork-divergence snapshot current.

## Resolution

The Container fork now contains:

- signed Apple ancestry merge
  `1bc31674629287f3386637db4c6d8652dc36602a`;
- signed named-builder test reconciliation
  `abed15fdd0cafe340f8aceb65080e4a88d0ceb0a`;
- signed documented fork head
  `302e31e71821f5dd3b395da2f299fc42a5bd6150`.

Compose commit `e4144a71c43a62876a492c8c1b9e89ef04429989` updates
`Package.swift`, `Package.resolved`, and `Tools/release/stack-refs.json` to the
same Container head. Containerization remains pinned to `6aa6e803`, and the
builder image remains pinned to immutable digest `sha256:09bdaafc…`.

## Validation

Container fork:

```sh
make check
make test
```

- 1,134 Swift tests in 131 suites passed, plus 94 XCTest cases.

Compose integration repository:

```sh
swift package resolve
make stack-consistency
make check
make coverage-check
make docker-compose-phase4-parity
```

- 1,118 Swift tests in 26 suites passed;
- Swift coverage: 91.38%;
- Go coverage: 90.06%;
- Phase 4 model parity passed against Docker Compose 5.3.1;
- the Phase 4 live aggregate passed with the exact matched runtime and stopped
  that runtime during cleanup.

## Release impact

The prior Current package remains a valid artifact of its immutable source
graph, but it is no longer the Phase 4 release candidate. A new Current package
must name the Compose commit containing `e4144a7` and Container
`302e31e71821…`. Stable `0.9.0` may proceed only after the exact new candidate,
hosted checks, Sonar analysis, Homebrew pair, and live runtime are verified.

## Commit tracking

- Apple issue: <https://github.com/apple/container/issues/2001>
- Apple pull request: <https://github.com/apple/container/pull/2002>
- Container fork head:
  `302e31e71821f5dd3b395da2f299fc42a5bd6150`.
- Compose pin:
  `e4144a71c43a62876a492c8c1b9e89ef04429989`.
