# Mission Control

Last updated: 2026-06-22 00:05:48 BST.

This file is the first stop before starting a `container-compose` capability slice. It keeps the runtime fork, upstream `apple/container` work, Docker Compose target behavior, and plugin branch state in one place so the active plan is not held in memory.

## Current Objective

Complete Docker Compose v2 local-development log behavior where `apple/container` can expose matching runtime primitives. The just-completed local slab retargets raw `container-compose logs --follow` to the forked runtime `ContainerClient.followLogs(id:options:)` stream so the plugin no longer rebuilds merged raw snapshots while following.

## Branch Map

| Repository | Branch | Purpose | Current state |
| --- | --- | --- | --- |
| `stephenlclarke/container-compose` | `logs-integration` | Compose-side proving branch for log behavior against the forked runtime | Active local worktree with Docker rotated-tail fixture updates and raw follow retargeting to `ContainerClient.followLogs(id:options:)` |
| `stephenlclarke/container` | `logs-integration-chris` | Fork integration branch layered around Chris George's log retrieval direction | Active local worktree with static rotated tail, policy model, disabled-capture, local driver/options, writer rotation, and raw rotation-aware follow handoff files |
| `stephenlclarke/container` | `logs-structured-record-storage` | Apple-facing structured log storage slice | PR-ready local/fork branch, not yet accepted upstream |
| `stephenlclarke/container` | `logs-structured-record-api` | Apple-facing structured record retrieval slice | PR-ready local/fork branch plus local cleanup commit, not yet accepted upstream |
| `apple/container` | `main` | Upstream runtime | Runtime primitives are still pending upstream review |

## Runtime Dependency Chain

1. Chris George's [apple/container#1592](https://github.com/apple/container/pull/1592) defines the base log retrieval-options direction.
2. [apple/container#1764](https://github.com/apple/container/pull/1764) adds `tail` and `until` retrieval filters.
3. [apple/container#1765](https://github.com/apple/container/pull/1765) adds Docker-compatible timestamp and duration parsing.
4. `logs-structured-record-storage` adds active `stdio.jsonl` structured records beside `stdio.log`.
5. `logs-structured-record-api` exposes active structured records and active record-file access.
6. The completed local slab adds static rotated replay and a bounded line-tail scan. Its handoff files are `ISSUE-logs-static-rotated-tail.md` and `PR-logs-static-rotated-tail.md` in the container fork.
7. The logging-policy stack starts with the typed local policy model. Its local code-bearing commit is `e41e630`, and its handoff files are `ISSUE-logs-local-policy-model.md` and `PR-logs-local-policy-model.md` in the container fork.
8. The completed disabled-capture slab adds the `.none` local storage policy behavior. Its local code-bearing commit is `6cbf778`, and its handoff files are `ISSUE-logs-disabled-local-capture.md` and `PR-logs-disabled-local-capture.md` in the container fork.
9. The parser slab maps local Docker-compatible logging drivers and options to `ContainerLogConfiguration`. Its local code-bearing commits are `f787d3d`, `9cca5b3`, and `ee28563`; its handoff files are `ISSUE-logs-local-driver-options.md` and `PR-logs-local-driver-options.md`.
10. The writer-rotation slab applies local `max-size` and `max-file` retention policy while writing persisted raw and structured logs. Its local code-bearing commit is `06862b7`; its handoff files are `ISSUE-logs-local-writer-rotation.md` and `PR-logs-local-writer-rotation.md`.
11. The raw rotation-aware follow slab adds `ContainerClient.followLogs(id:options:)`, XPC route `containerFollowLogs`, and a runtime-owned raw stream across rename-based active log rotation. Its handoff files are `ISSUE-logs-rotation-aware-follow.md` and `PR-logs-rotation-aware-follow.md`.
12. Later slabs add structured/timestamped rotation-aware follow over retained `stdio.jsonl` records.

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

Raw rotation-aware follow support across the container fork and compose plugin.

Done:

- Base log retrieval PRs are identified and tracked.
- Structured storage and active retrieval branches are split from the integration branch.
- Compose log manager already requests `ContainerLogReplayOptions(includeRotated: true)` for static raw and structured replay.
- The local `container` integration branch already contains writer-level local rotation behavior from commit `06862b7`.
- The local `container` integration branch now exposes raw `ContainerClient.followLogs(id:options:)` with Docker-style initial tail replay and rename-based active-file follow.
- `container-compose` now calls `ContainerClient.followLogs(id:options:)` for raw followed logs and keeps only Compose line reconstruction and container-stop flushing in the plugin.

Completed locally:

- Finished the typed local logging policy model, disabled-capture, and local driver/options handoffs after the static rotated replay slab.
- Added focused coverage for reopening existing active log files before applying size-based rotation.
- Added Apple-template-aligned writer-rotation handoff files so the change can become an Apple-facing PR after the logging policy model and parser slices settle.
- Added an optional Docker Compose fixture harness for rotated `json-file` and `local` log tail behavior.
- Captured Docker Engine 29.2.1 / Docker Compose 5.1.4 parity evidence for `logs --tail 5`, `logs --tail 0`, `logs --tail -1`, and `logs --tail all`.
- Added Apple-template-aligned raw rotation-aware follow handoff files in the container fork.
- Removed the plugin-side raw merged-snapshot polling path after switching the adapter to the runtime follow stream.

Next:

- Expand Docker comparison fixtures beyond rotated tail to timestamp filters, blank/CRLF records, final partial records, `--tail 0 --follow`, and selected multi-replica follow behavior.
- Design and split structured/timestamped rotation-aware follow over retained `stdio.jsonl` records.

## Open Blockers

- `apple/container` has not accepted the retrieval parser stack yet, so released `container-compose` branches must still distinguish upstream support from fork-only support.
- `apple/container` still needs an accepted raw rotation-aware follow stream before released `container-compose` can rely on that runtime stream without depending on the fork.
- Structured/timestamped rotated follow still needs an apple/container runtime cursor over retained `stdio.jsonl` records.
- Remote logging drivers and driver-specific metadata remain runtime gaps; local `json-file`, `local`, `none`, `max-size`, and `max-file` stay fork-only until upstream runtime policy lands.

## Checkpoint Format

End each slice with:

- Done: what changed.
- Changed: repo, branch, commit.
- Validated: exact commands and results.
- Blocked: remaining upstream/runtime/plugin blockers.
- Next: the smallest useful follow-up.
