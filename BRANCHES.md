# Branch Guide

This repository keeps two public environments: `main` for people who want to test a frozen plugin build, and `develop` for active integration work that can move quickly. The companion [`stephenlclarke/container`](https://github.com/stephenlclarke/container) fork uses the same branch names so testers and contributors can check out a matching plugin/runtime pair.

## Environment Branches

| Environment | `container-compose` branch | `container` fork branch | Audience | Movement rule |
| --- | --- | --- | --- | --- |
| Stable | `main` | `main` | People trying the app/plugin without chasing active development | Move only after a validation pass. Treat this as frozen between promoted snapshots. |
| Development | `develop` | `develop` | Day-to-day development and integration testing | Move freely as work lands, including fork-backed runtime work that has not been accepted upstream. |

`Package.swift` references the `container` checkout as a sibling path dependency at `../container`, so the active branch in that checkout is part of the selected environment. For the frozen tester environment, use `main` in both repositories. For active development, use `develop` in both repositories.

```sh
git -C ~/github/container-compose checkout main
git -C ~/github/container checkout main
```

```sh
git -C ~/github/container-compose checkout develop
git -C ~/github/container checkout develop
```

The current integration stack still pins [`stephenlclarke/containerization`](https://github.com/stephenlclarke/containerization) `integration/blkio-runtime` through `Package.swift` and `Package.resolved` until the block I/O runtime API from [`apple/containerization#739`](https://github.com/apple/containerization/pull/739) is accepted upstream. There is no separate stable/develop lane for `containerization` right now; the pin is part of the selected plugin/runtime environment.

## Default And Compatibility Branches

| Branch | Purpose |
| --- | --- |
| `main` | Default repository branch and public stable lane. It may require the matching `stephenlclarke/container` `main` branch when the promoted plugin snapshot depends on fork-backed runtime primitives. |
| `apple-container-compatible` | Upstream-only compatibility branch for users who want behavior available from released or accepted [`apple/container`](https://github.com/apple/container) primitives. |
| `regression` | Short-lived upstream compatibility, dependency, CodeQL, and canary work. It should stay close to `main` or `develop` depending on the issue being checked. |

Do not maintain extra frozen branches. Future promotions should move validated `develop` snapshots into `main`.

## Integration And Archive Branches

| Branch | Status | Notes |
| --- | --- | --- |
| `compose-v2-preview` | Legacy preview archive | Preserves older preview harness and handoff state. Do not treat this as the current compatibility target. |

The former broad `logs-integration`, `logs-integration-chris`, `full-compose-preview`, and `full-compose-runtime` branches have been folded into the current `develop` / `main` lane model or deleted as stale archives. Historical handoff notes may still mention those names when they identify where a slice originally came from, but new work should not target them.

## Upstreaming Rule

Fork-backed runtime changes should still be split into small Apple-facing branches before opening pull requests against [`apple/container`](https://github.com/apple/container). Keep one runtime capability per PR where practical, with focused tests and no Compose-specific policy in the runtime branch. The `develop` branches can carry integration work so `container-compose` can keep moving, while upstream PR branches remain easy to review and cherry-pick.

Compose-specific behavior stays in this repository, including service fan-out, replica selection, prefixes, colors, selected-service ordering, Docker Compose CLI parsing, and Docker Compose output formatting.
