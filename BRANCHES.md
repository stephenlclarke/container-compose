# Branch Guide

This repository deliberately keeps two public compatibility tracks: one that works with released upstream [`apple/container`](https://github.com/apple/container), and one that pairs with a forked runtime while the missing primitives are being upstreamed in small reviewable pull requests.

## Visitor Branches

| Branch | Runtime dependency | Audience | Purpose |
| --- | --- | --- | --- |
| `apple-container-compatible` | [`apple/container`](https://github.com/apple/container) `main` or an accepted upstream release | Users who want only functionality available from the upstream Apple runtime | Stable compatibility track. Unsupported Docker Compose surfaces fail clearly when the first missing primitive is in upstream `apple/container`. |
| `full-compose-preview` | [`stephenlclarke/container`](https://github.com/stephenlclarke/container) `full-compose-runtime` | Users who want the broadest current Docker Compose v2 preview | Fork-backed preview track for functionality implemented locally while the runtime pieces are still waiting for upstream `apple/container` acceptance. |
| `main` | [`apple/container`](https://github.com/apple/container) | General visitors | Protected default branch. Mirrors the upstream-compatible support story and should not require a forked runtime. |
| `develop` | [`apple/container`](https://github.com/apple/container) | Contributors | Protected development branch for upstream-compatible work before batched promotion to `main`. |
| `regression` | [`apple/container`](https://github.com/apple/container) | Maintainers | Short-lived upstream compatibility, dependency, CodeQL, and canary work. It should stay close to `develop` and upstream `apple/container`. |

## Internal And Handoff Branches

| Branch | Status | Notes |
| --- | --- | --- |
| `logs-integration` | Active handoff branch | Implementation branch backing `full-compose-preview`. It may move faster than the visitor-facing branch name and can depend on fork-only runtime APIs. |
| `compose-v2-preview` | Legacy preview archive | Preserves the older preview harness and handoff state. Prefer `full-compose-preview` for current fork-backed testing. Do not treat this as the current compatibility target. |

## Container Fork Branches

The companion runtime fork uses the same separation:

| Repository | Branch | Purpose |
| --- | --- | --- |
| [`stephenlclarke/container`](https://github.com/stephenlclarke/container) | `main` | Mirror of upstream `apple/container` main. Do not land fork-only product work here. |
| [`stephenlclarke/container`](https://github.com/stephenlclarke/container) | `full-compose-runtime` | Visitor/runtime integration branch containing primitives needed by `container-compose` preview work before they are accepted upstream. Pair this with `container-compose` `full-compose-preview`. |
| [`stephenlclarke/container`](https://github.com/stephenlclarke/container) | `logs-integration-chris` | Active log-runtime integration branch that fits around Chris George's [`apple/container#1592`](https://github.com/apple/container/pull/1592) direction. Use this to prove end-to-end Compose log behavior before slicing more upstream PRs. |
| [`stephenlclarke/container`](https://github.com/stephenlclarke/container) | `fix-loghandler-deprecation-warnings` | Apple-facing PR branch for SwiftLog handler deprecation cleanup, tracked by [`apple/container#1758`](https://github.com/apple/container/pull/1758). Keep it small and free of Compose policy. |
| [`stephenlclarke/container`](https://github.com/stephenlclarke/container) | `logs-tail-until-options` | Apple-facing PR branch for log tail/until retrieval filters, tracked by [`apple/container#1764`](https://github.com/apple/container/pull/1764). |
| [`stephenlclarke/container`](https://github.com/stephenlclarke/container) | `logs-docker-timestamp-parser` | Apple-facing PR branch for Docker-compatible log timestamp parsing, tracked by [`apple/container#1765`](https://github.com/apple/container/pull/1765). |

Older fork branches such as `logs-integration`, `logs-tail-until-delta`, `logs-unix-timestamp-filters`, and `logs-retrieval-options` are retained as staging/history references. Prefer `full-compose-runtime` for a runnable fork-backed runtime and the Apple-facing PR branches for upstream review.

## Upstreaming Rule

Fork-backed runtime changes should be split into small Apple-facing branches before opening pull requests against [`apple/container`](https://github.com/apple/container). Keep one runtime capability per PR where practical, with focused tests and no Compose-specific policy in the runtime branch. The fork can carry an integration branch so `container-compose` can keep moving, but upstream PR branches should remain easy to review and cherry-pick.

Compose-specific behavior stays in this repository, including service fan-out, replica selection, prefixes, colors, selected-service ordering, and Docker Compose CLI formatting.
