# Pull request: refresh and validate the complete upstream stack

<!-- markdownlint-disable MD013 -->

## Summary

- Consume Apple Container maintenance through `f0b2b96` without rewriting
  upstream history.
- Fix the reproducible privileged-loopback regression in one reusable macOS
  runtime primitive.
- Retain the useful health-test reliability change from a superseded fork pull
  request.
- Pin Compose, SwiftPM, and release provenance to the same signed Container
  revision.
- Record bot, bug, and upstream pull-request dispositions in the central
  handoff repository.
- Validate the matched stack, the live Compose runtime, and Docker Compose V2
  parity on a physical MacBook Pro.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update
- [x] Dependency provenance update

## Motivation and Context

Phase work cannot safely continue on stale runtime history. This slice refreshes
every Apple-facing dependency first, resolves the one new reproducible upstream
runtime defect, and gives Apple small commits that can be reviewed or applied
independently. Docker compatibility policy and release orchestration remain in
`container-compose`.

No Windows behavior is introduced. Linux guest behavior is included only when
it is implementable and testable through Apple's macOS runtime.

## Apple-shaped commits

- `3cab3a085a472057f3dd54c391cc4fd5c41fe36a`
  (`chore(upstream): sync Apple test fixtures`) retains Apple merge parentage
  and adjusts only fork fixtures affected by Apple's typed `WarmupImage` API.
- `71cdae6b695508086cef81b94e9ad77a633635f6`
  (`fix(network): bind privileged loopback ports`) changes the port-forwarding
  primitive and adds its focused unit and live integration coverage.
- `659a01733ac03c07624b545fb552f1536f80b203`
  (`test(health): avoid unread stdout pipe`) is test-only and removes a source
  of child-process blocking.
- `cb87e7d5b67203548fb970ce2e551494b79a77c7`
  (`chore(docs): centralize upstream handoffs`) removes downstream copies of
  these handoffs so Compose remains the single review source.

## Compose commits

- `b59c33d406e8a19c1dbb6ee74c8457cc64960ab7`
  (`chore(deps): refresh matched Container runtime`) updates `Package.swift`,
  `Package.resolved`, `Tools/release/stack-refs.json`, and the current README
  provenance snapshot to the same immutable Container tip.
- `f8eeefa0a84bbccb896896acafdcc24adf3ee1ff`
  records the Apple fixture synchronization handoff.
- `4d624e8b48c0d1a0e7a1b3ed0cec6d25d6c56db0`
  records the health-test reliability handoff.
- `cf4325ad92167dccf6417e20524b7b029e24a3cc`
  records the privileged-loopback handoff.

## Upstream and automation disposition

- Builder shim and Containerization were already current with Apple.
- Container was merged through Apple `f0b2b96`; the final fork is zero commits
  behind Apple.
- Dependabot pull request `stephenlclarke/homebrew-tap#1` was merged as signed
  commit `7a242c690420223b98b34bc33416aee06b651a4a`.
- `apple/container#1933` and fork pull request `#6` were documented and closed
  as superseded.
- `apple/container#1965` was revalidated and marked ready; `#1934`, `#1935`,
  and `apple/containerization#799` need maintainer review but no new code.
- `apple/container#1985` is fixed here. `#1986`, `#1992`, `#1967`, and `#1987`
  require no additional change for the reasons recorded in the paired issue
  handoff.

## Docker Compose compatibility

All 56 declared strict parity targets passed against Docker Compose V2 5.3.1
and Docker Engine 29.2.1. The matrix covers CLI surface, configuration,
environment, build, volumes and mounts, networking, namespaces, security,
resource controls, events, state, lifecycle, and restart policy.

Docker-specific normalization and compatibility remain in Compose. Apple fork
changes expose or correct only general macOS runtime behavior.

## VHS demonstration

The README recording is generated from `docs/container-compose-demo.tape` on a
physical MacBook Pro with the matched Current packages. The tape types actual
`container` and `container compose` commands and displays their output,
including startup, status, HTTP requests, persistent-volume reuse, teardown,
and shutdown. It uses no replay, marker, or transcript helper commands.

## Testing

- [x] Signed Conventional Commits
- [x] Builder shim tests/build/license checks; 44.4% aggregate line coverage
- [x] Containerization: 646 unit tests and 175 passing integration tests
- [x] Container: 1,131 unit, 3 warmup, 238 concurrent, and 143 serial tests
- [x] Container combined line coverage: 51.61%
- [x] Compose: 1,113 Swift tests and 25 live runtime tests
- [x] Compose Swift coverage: 91.39% (90% floor)
- [x] Compose Go coverage: 90.06% (85% floor)
- [x] Compose release/CI/coverage tool tests: 161
- [x] Docker Compose V2 strict parity: 56 of 56 targets
- [x] Markdown, licenses, stack consistency, and diff checks

```sh
CONTAINER_BUILDER_SHIM_STACK_REPO=/path/to/container-builder-shim \
CONTAINERIZATION_STACK_REPO=/path/to/containerization \
CONTAINER_STACK_REPO=/path/to/container \
HOMEBREW_TAP_REPO=/path/to/homebrew-tap \
make release-gate
```

## Release and review checklist

- [x] All upstream repositories were fetched and compared before code changes.
- [x] Every fork commit is independently reviewable and signed.
- [x] Compose consumes one immutable, matched runtime revision everywhere.
- [x] User worktrees were left untouched.
- [x] Documentation describes the current code and live VHS behavior.

Publication uses the mutable [Current prerelease](https://github.com/stephenlclarke/container-compose/releases/tag/current).
Exact-main hosted CI and SonarQube are mandatory publication authorities. The
workflow then binds the release, its two Homebrew formulae, package assets,
quality snapshot, and live VHS GIF to that same commit. Publication starts a
new seven-day Phase 3 soak; Phase 4 remains blocked until that interval and the
Phase 3 stable and SonarQube gates are complete.
