# Branch Guide

This repository now keeps two public environments: `release` for people who want to test a frozen plugin build, and `develop` for active integration work that can move quickly. The companion [`stephenlclarke/container`](https://github.com/stephenlclarke/container) fork uses the same branch names so testers and contributors can check out a matching plugin/runtime pair.

## Environment Branches

| Environment | `container-compose` branch | `container` fork branch | Audience | Movement rule |
| --- | --- | --- | --- | --- |
| Release | `release` | `release` | People trying the app/plugin without chasing active development | Move only after a validation pass. Treat this as frozen between promoted snapshots. |
| Development | `develop` | `develop` | Day-to-day development and integration testing | Move freely as work lands, including fork-backed runtime work that has not been accepted upstream. |

`Package.swift` references the `container` checkout as a sibling path dependency at `../container`, so the active branch in that checkout is part of the selected environment. For the frozen tester environment, use `release` in both repositories. For active development, use `develop` in both repositories.

```sh
git -C ~/github/container-compose checkout release
git -C ~/github/container checkout release
```

```sh
git -C ~/github/container-compose checkout develop
git -C ~/github/container checkout develop
```

The current integration stack still pins [`stephenlclarke/containerization`](https://github.com/stephenlclarke/containerization) `integration/blkio-runtime` through `Package.swift` and `Package.resolved` until the block I/O runtime API from [`apple/containerization#739`](https://github.com/apple/containerization/pull/739) is accepted upstream. There is no separate containerization release/develop lane for this repo right now; the pin is part of the selected plugin/runtime environment.

## Default And Compatibility Branches

| Branch | Purpose |
| --- | --- |
| `main` | Default repository branch and upstream-compatible baseline. It should not require fork-only runtime behavior unless it is intentionally promoted to become the release lane later. |
| `apple-container-compatible` | Upstream-only compatibility branch for users who want behavior available from released or accepted [`apple/container`](https://github.com/apple/container) primitives. |
| `regression` | Short-lived upstream compatibility, dependency, CodeQL, and canary work. It should stay close to `main` or `develop` depending on the issue being checked. |

If `main` becomes the public release lane later, promote `release` into `main` deliberately after the same validation gate. Do not maintain two silently divergent frozen branches.

## Integration And Archive Branches

| Branch | Status | Notes |
| --- | --- | --- |
| `logs-integration` | Superseded by `develop` as the public development lane | Existing `container-compose` proving branch for log, lifecycle, copy, event, and runtime-control behavior against the forked runtime. Keep it as a history and work-in-progress reference while the current uncommitted cleanup is drained. |
| `logs-integration-chris` | Superseded by `develop` as the public development lane in the `container` fork | Existing runtime proving branch layered around Chris George's log retrieval direction plus the lifecycle primitives needed by Compose. |
| `full-compose-preview` | Legacy preview archive | Older fork-backed visitor branch. Prefer `release` for testers and `develop` for active work. |
| `full-compose-runtime` | Legacy runtime preview archive in the `container` fork | Older fork-backed runtime visitor branch. Prefer the fork `release` branch for testers and fork `develop` for active work. |
| `compose-v2-preview` | Legacy preview archive | Preserves older preview harness and handoff state. Do not treat this as the current compatibility target. |

## Upstreaming Rule

Fork-backed runtime changes should still be split into small Apple-facing branches before opening pull requests against [`apple/container`](https://github.com/apple/container). Keep one runtime capability per PR where practical, with focused tests and no Compose-specific policy in the runtime branch. The `develop` branches can carry integration work so `container-compose` can keep moving, while upstream PR branches remain easy to review and cherry-pick.

Compose-specific behavior stays in this repository, including service fan-out, replica selection, prefixes, colors, selected-service ordering, Docker Compose CLI parsing, and Docker Compose output formatting.
