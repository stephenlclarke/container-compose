# Branch Guide

This repository deliberately keeps two public compatibility tracks.

## Visitor Branches

| Branch | Runtime dependency | Audience | Purpose |
| --- | --- | --- | --- |
| `apple-container-compatible` | [`apple/container`](https://github.com/apple/container) `main` or an accepted upstream release | Users who want only functionality available from the upstream Apple runtime | Stable compatibility track. Unsupported Docker Compose surfaces fail clearly when the first missing primitive is in upstream `apple/container`. |
| `full-compose-preview` | [`stephenlclarke/container`](https://github.com/stephenlclarke/container) `full-compose-runtime` | Users who want the broadest current Docker Compose v2 preview | Preview track for functionality that is implemented locally but still waiting for upstream `apple/container` acceptance. |
| `main` | [`apple/container`](https://github.com/apple/container) | General visitors | Protected default branch. Mirrors the upstream-compatible support story. |
| `develop` | [`apple/container`](https://github.com/apple/container) | Contributors | Protected development branch for upstream-compatible work before batched promotion to `main`. |
| `regression` | [`apple/container`](https://github.com/apple/container) | Maintainers | Short-lived upstream compatibility, dependency, CodeQL, and canary work. |

## Internal And Handoff Branches

| Branch | Status | Notes |
| --- | --- | --- |
| `logs-integration` | Active handoff branch | Implementation branch backing `full-compose-preview`. It may move faster than the visitor-facing branch name. |
| `compose-v2-preview` | Legacy preview archive | Preserves the older preview harness and handoff state. Prefer `full-compose-preview` for current fork-backed testing. |

## Container Fork Branches

The companion runtime fork uses the same separation:

| Repository | Branch | Purpose |
| --- | --- | --- |
| [`stephenlclarke/container`](https://github.com/stephenlclarke/container) | `main` | Mirror of upstream `apple/container` main. Do not land fork-only product work here. |
| [`stephenlclarke/container`](https://github.com/stephenlclarke/container) | `full-compose-runtime` | Integration branch containing runtime primitives needed by `container-compose` preview work before they are accepted upstream. |
| [`stephenlclarke/container`](https://github.com/stephenlclarke/container) | `logs-tail-until-options` | Apple-facing PR slice for log tail/until retrieval filters. |
| [`stephenlclarke/container`](https://github.com/stephenlclarke/container) | `logs-docker-timestamp-parser` | Apple-facing PR slice for Docker-compatible log timestamp parsing. |

## Upstreaming Rule

Fork-backed runtime changes should be split into small Apple-facing branches before opening pull requests against [`apple/container`](https://github.com/apple/container). Keep one runtime capability per PR where practical, with focused tests and no Compose-specific policy in the runtime branch.

Compose-specific behavior stays in this repository, including service fan-out, replica selection, prefixes, colors, selected-service ordering, and Docker Compose CLI formatting.
