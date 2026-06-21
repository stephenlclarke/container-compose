# Mission Control

Last updated: 2026-06-21 22:51:12 BST.

This file is the first stop before starting a `container-compose` capability slice. It keeps the runtime fork, upstream `apple/container` work, Docker Compose target behavior, and plugin branch state in one place so the active plan is not held in memory.

## Current Objective

Complete Docker Compose v2 local-development log behavior where `apple/container` can expose matching runtime primitives. The just-completed local slab is log-driver and local option parsing, because it bridges the runtime logging policy model to Docker-compatible `--log-driver` and `--log-opt` inputs without adding Compose presentation policy to `apple/container`.

## Branch Map

| Repository | Branch | Purpose | Current state |
| --- | --- | --- | --- |
| `stephenlclarke/container-compose` | `logs-integration` | Compose-side proving branch for log behavior against the forked runtime | Active local worktree with log-driver/local-option tracking updates |
| `stephenlclarke/container` | `logs-integration-chris` | Fork integration branch layered around Chris George's log retrieval direction | Active local worktree with static rotated tail, policy model, disabled-capture, and local driver/options handoff files |
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
9. The active parser slab maps local Docker-compatible logging drivers and options to `ContainerLogConfiguration`. Its local code-bearing commits are `f787d3d`, `9cca5b3`, and `ee28563`; its handoff files are `ISSUE-logs-local-driver-options.md` and `PR-logs-local-driver-options.md`.
10. Later slabs add writer-level rotation and a rotation-aware follow cursor or stream.

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

Log-driver and local option parsing.

Done:

- Base log retrieval PRs are identified and tracked.
- Structured storage and active retrieval branches are split from the integration branch.
- Compose log manager already requests `ContainerLogReplayOptions(includeRotated: true)` for static raw and structured replay.

Completed locally:

- Finished the typed local logging policy model and disabled-capture handoffs after the static rotated replay slab.
- Confirmed the local `container` integration branch already contains the log-driver and local option parser behavior from commits `f787d3d`, `9cca5b3`, and `ee28563`.
- Added focused coverage for `json-file` with local retention options before writing the handoff.
- Added Apple-template-aligned log-driver/local-option handoff files so the change can become an Apple-facing PR after the logging policy model and disabled-capture slices settle.

Next:

- Split writer-level local rotation from local commit `06862b7`.
- Add or update Docker comparison fixtures for rotated `docker compose logs --tail` output.
- After runtime validation, remove any plugin-side workaround that duplicates accepted runtime behavior.

## Open Blockers

- `apple/container` has not accepted the retrieval parser stack yet, so released `container-compose` branches must still distinguish upstream support from fork-only support.
- `apple/container` still needs an accepted rotation-aware follow cursor or stream before long-lived raw `logs --follow` can stop using plugin-side polling.
- Remote logging drivers and driver-specific metadata remain runtime gaps; local `json-file`, `local`, `none`, `max-size`, and `max-file` stay fork-only until upstream runtime policy lands.

## Checkpoint Format

End each slice with:

- Done: what changed.
- Changed: repo, branch, commit.
- Validated: exact commands and results.
- Blocked: remaining upstream/runtime/plugin blockers.
- Next: the smallest useful follow-up.
