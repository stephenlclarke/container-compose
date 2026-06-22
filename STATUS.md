# Mission Control

Last updated: 2026-06-22 01:07:02 BST.

This file is the first stop before starting a `container-compose` capability slice. It keeps the runtime fork, upstream `apple/container` work, Docker Compose target behavior, and plugin branch state in one place so the active plan is not held in memory.

## Current Objective

Complete Docker Compose v2 local-development behavior where `apple/container` can expose matching runtime primitives. The log slabs retargeted raw `container-compose logs --follow` to `ContainerClient.followLogs(id:options:)` and structured/timestamped followed logs to `ContainerClient.followLogRecords(id:options:)` on the forked runtime, so the plugin no longer polls merged snapshots or active record files while following. The active lifecycle slab now uses fork-backed `ContainerSnapshot.exitCode` metadata for stopped-container `wait` replay and `depends_on.condition: service_completed_successfully`.

## Branch Map

| Repository | Branch | Purpose | Current state |
| --- | --- | --- | --- |
| `stephenlclarke/container-compose` | `logs-integration` | Compose-side proving branch for log and lifecycle behavior against the forked runtime | Active local worktree with Docker rotated-tail fixture updates, raw follow retargeting to `ContainerClient.followLogs(id:options:)`, structured follow retargeting to `ContainerClient.followLogRecords(id:options:)`, stopped-container `wait` replay, and `service_completed_successfully` dependency gates |
| `stephenlclarke/container` | `logs-integration-chris` | Fork integration branch layered around Chris George's log retrieval direction plus lifecycle primitives needed by Compose | Active local worktree with static rotated tail, policy model, disabled-capture, local driver/options, writer rotation, raw rotation-aware follow, structured rotation-aware follow handoff files, and the #1562 exit-metadata cherry-pick |
| `stephenlclarke/container` | `logs-structured-record-storage` | Apple-facing structured log storage slice | PR-ready local/fork branch, not yet accepted upstream |
| `stephenlclarke/container` | `logs-structured-record-api` | Apple-facing structured record retrieval slice | PR-ready local/fork branch plus local cleanup commit, not yet accepted upstream |
| `apple/container` | `main` | Upstream runtime | Runtime primitives are still pending upstream review |

## Runtime Dependency Chain

1. Chris George's [apple/container#1592](https://github.com/apple/container/pull/1592) defines the base log retrieval-options direction.
2. [apple/container#1764](https://github.com/apple/container/pull/1764) adds `tail` and `until` retrieval filters.
3. [apple/container#1765](https://github.com/apple/container/pull/1765) adds Docker-compatible timestamp and duration parsing.
4. `logs-structured-record-storage` adds active `stdio.jsonl` structured records beside `stdio.log`.
5. `logs-structured-record-api` exposes active structured records and active record-file access for snapshot/replay clients.
6. The completed local slab adds static rotated replay and a bounded line-tail scan. Its handoff files are `ISSUE-logs-static-rotated-tail.md` and `PR-logs-static-rotated-tail.md` in the container fork.
7. The logging-policy stack starts with the typed local policy model. Its local code-bearing commit is `e41e630`, and its handoff files are `ISSUE-logs-local-policy-model.md` and `PR-logs-local-policy-model.md` in the container fork.
8. The completed disabled-capture slab adds the `.none` local storage policy behavior. Its local code-bearing commit is `6cbf778`, and its handoff files are `ISSUE-logs-disabled-local-capture.md` and `PR-logs-disabled-local-capture.md` in the container fork.
9. The parser slab maps local Docker-compatible logging drivers and options to `ContainerLogConfiguration`. Its local code-bearing commits are `f787d3d`, `9cca5b3`, and `ee28563`; its handoff files are `ISSUE-logs-local-driver-options.md` and `PR-logs-local-driver-options.md`.
10. The writer-rotation slab applies local `max-size` and `max-file` retention policy while writing persisted raw and structured logs. Its local code-bearing commit is `06862b7`; its handoff files are `ISSUE-logs-local-writer-rotation.md` and `PR-logs-local-writer-rotation.md`.
11. The raw rotation-aware follow slab adds `ContainerClient.followLogs(id:options:)`, XPC route `containerFollowLogs`, and a runtime-owned raw stream across rename-based active log rotation. Its handoff files are `ISSUE-logs-rotation-aware-follow.md` and `PR-logs-rotation-aware-follow.md`.
12. The structured rotation-aware follow slab adds `ContainerClient.followLogRecords(id:options:)`, XPC route `containerFollowLogRecords`, and a runtime-owned structured stream across retained `stdio.jsonl` records. Its handoff files are `ISSUE-logs-structured-rotation-aware-follow.md` and `PR-logs-structured-rotation-aware-follow.md`.
13. The exit-metadata slab cherry-picks [`apple/container#1562`](https://github.com/apple/container/pull/1562) into the fork as signed commit `9b6f743`, exposing `ContainerSnapshot.exitCode` and `exitedDate` for stopped containers.

## Docker/Compose Reference Targets

- Docker Compose `logs` documents `--follow`, `--index`, `--no-color`, `--no-log-prefix`, `--since`, `--tail`, `--timestamps`, and `--until`: [docker compose logs](https://docs.docker.com/reference/cli/docker/compose/logs/).
- Compose service `logging` documents `driver` plus driver-specific `options`: [Compose services logging](https://docs.docker.com/reference/compose-file/services/#logging).
- Docker `json-file` logging documents `max-size` and `max-file`: [JSON file logging driver](https://docs.docker.com/engine/logging/drivers/json-file/).
- Docker `local` logging documents rotated local retained log storage: [Local file logging driver](https://docs.docker.com/engine/logging/drivers/local/).

## What Belongs Where

| Behavior | Owner |
| --- | --- |
| Runtime log storage, replay filters, rotated replay, cursor semantics, persisted logging policy | `apple/container` or the `stephenlclarke/container` fork while upstreaming |
| Compose service selection, replica fan-out, `--index`, prefixes, colors, `--no-log-prefix`, command formatting | `container-compose` |
| Compose file merge, interpolation, profiles, includes, extensions | `compose-go` normalizer helper |
| Docker output parity fixtures and local comparison harnesses | `container-compose`, with runtime assertions mirrored in `container` tests when the primitive is runtime-owned |

## Active Slab

Lifecycle completion support across the container fork and compose plugin, starting with `service_completed_successfully` and stopped-container `wait` replay.

Done:

- Base log retrieval PRs are identified and tracked.
- Structured storage and active retrieval branches are split from the integration branch.
- Compose log manager already requests `ContainerLogReplayOptions(includeRotated: true)` for static raw and structured replay.
- The local `container` integration branch already contains writer-level local rotation behavior from commit `06862b7`.
- The local `container` integration branch now exposes raw `ContainerClient.followLogs(id:options:)` with Docker-style initial tail replay and rename-based active-file follow.
- `container-compose` now calls `ContainerClient.followLogs(id:options:)` for raw followed logs and keeps only Compose line reconstruction and container-stop flushing in the plugin.
- The local `container` integration branch now exposes structured `ContainerClient.followLogRecords(id:options:)` with Docker-style initial replay, logical-line filtering, retained `stdio.jsonl` replay, active-file rotation, final partial-line flushing, and `tail`/`since`/`until` semantics.
- `container-compose` now calls `ContainerClient.followLogRecords(id:options:)` for followed timestamped/time-filtered logs and keeps only Compose formatting, prefixing, color, and service fan-out in the plugin.

Completed locally:

- Finished the typed local logging policy model, disabled-capture, and local driver/options handoffs after the static rotated replay slab.
- Added focused coverage for reopening existing active log files before applying size-based rotation.
- Added Apple-template-aligned writer-rotation handoff files so the change can become an Apple-facing PR after the logging policy model and parser slices settle.
- Added an optional Docker Compose fixture harness for rotated `json-file` and `local` log tail behavior.
- Captured Docker Engine 29.2.1 / Docker Compose 5.1.4 parity evidence for `logs --tail 5`, `logs --tail 0`, `logs --tail -1`, and `logs --tail all`.
- Added Apple-template-aligned raw rotation-aware follow handoff files in the container fork.
- Removed the plugin-side raw merged-snapshot polling path after switching the adapter to the runtime follow stream.
- Added Apple-template-aligned structured rotation-aware follow handoff files in the container fork.
- Removed the plugin-side active-record-file structured follow path after switching the adapter to the runtime structured follow stream.
- Cherry-picked and adapted [`apple/container#1562`](https://github.com/apple/container/pull/1562) into the local container fork so stopped container snapshots expose `exitCode` and `exitedDate`.
- Projected exit metadata through `ComposeContainerSummary`.
- Implemented `depends_on.condition: service_completed_successfully` for `up` and one-off `run`, including fast-exited dependency replay, live dependency waiting, and non-zero dependency failure before dependents start.
- Updated `container compose wait` to replay stored exit codes for already-stopped service containers when the forked runtime provides exit metadata.

Next:

- Continue the lifecycle topic with `depends_on.condition: service_healthy`, comparing [`apple/container#1502`](https://github.com/apple/container/issues/1502) and [`apple/container#1504`](https://github.com/apple/container/pull/1504) before implementing the fork/runtime API.
- Then continue with service `restart` / `deploy.restart_policy`, comparing [`apple/container#286`](https://github.com/apple/container/issues/286) and [`apple/container#1258`](https://github.com/apple/container/pull/1258).
- Keep the log comparison fixtures as a parallel backlog item, but do not switch away from the lifecycle topic until health/restart are implemented or blocked.

## Open Blockers

- `apple/container` has not accepted the retrieval parser stack yet, so released `container-compose` branches must still distinguish upstream support from fork-only support.
- `apple/container` still needs an accepted raw rotation-aware follow stream before released `container-compose` can rely on that runtime stream without depending on the fork.
- `apple/container` still needs an accepted structured rotation-aware follow stream before released `container-compose` can rely on `ContainerClient.followLogRecords(id:options:)` without depending on the fork.
- Remote logging drivers and driver-specific metadata remain runtime gaps; local `json-file`, `local`, `none`, `max-size`, and `max-file` stay fork-only until upstream runtime policy lands.
- `apple/container` still needs accepted exit metadata before released `container-compose` can rely on stopped-container `wait` replay or `service_completed_successfully` without depending on the fork.
- `apple/container` still needs health status and restart-policy primitives before `service_healthy`, service `restart`, or `deploy.restart_policy` can move out of rejected runtime gaps.

## Checkpoint Format

End each slice with:

- Done: what changed.
- Changed: repo, branch, commit.
- Validated: exact commands and results.
- Blocked: remaining upstream/runtime/plugin blockers.
- Next: the smallest useful follow-up.
