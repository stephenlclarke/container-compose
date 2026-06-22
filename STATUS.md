# Mission Control

Last updated: 2026-06-22 04:08:30 BST.

This file is the first stop before starting a `container-compose` capability slice. It keeps the runtime fork, upstream `apple/container` work, Docker Compose target behavior, and plugin branch state in one place so the active plan is not held in memory.

## Current Objective

Complete Docker Compose v2 local-development behavior where `apple/container` can expose matching runtime primitives. The log slabs retargeted raw `container-compose logs --follow` to `ContainerClient.followLogs(id:options:)` and structured/timestamped followed logs to `ContainerClient.followLogRecords(id:options:)` on the forked runtime, so the plugin no longer polls merged snapshots or active record files while following. The active lifecycle/config slab now uses fork-backed `ContainerSnapshot.exitCode` metadata for stopped-container `wait` replay, `depends_on.condition: service_completed_successfully`, explicit service healthchecks, Dockerfile-inherited image healthchecks, `depends_on.condition: service_healthy`, service-level `restart`, fork-backed `deploy.restart_policy` mode/retry/timing support, and plugin-side materialization for Docker Compose runtime configs/secrets that can be represented as read-only local file mounts.

## Branch Map

| Repository | Branch | Purpose | Current state |
| --- | --- | --- | --- |
| `stephenlclarke/container-compose` | `logs-integration` | Compose-side proving branch for log and lifecycle behavior against the forked runtime | Active local worktree with Docker rotated-tail fixture updates, raw follow retargeting to `ContainerClient.followLogs(id:options:)`, structured follow retargeting to `ContainerClient.followLogRecords(id:options:)`, stopped-container `wait` replay, `service_completed_successfully`, explicit and Dockerfile-inherited healthcheck flag mapping, `service_healthy` dependency gates, service `restart` mapping, `deploy.restart_policy` condition/max-attempt/timing mapping, and local materialization for runtime `configs.content`, `configs.environment`, and `secrets.environment` grants |
| `stephenlclarke/container` | `logs-integration-chris` | Fork integration branch layered around Chris George's log retrieval direction plus lifecycle primitives needed by Compose | Active local worktree with static rotated tail, policy model, disabled-capture, local driver/options, writer rotation, raw rotation-aware follow, structured rotation-aware follow handoff files, the #1562 exit-metadata cherry-pick, health status/configuration/observer/CLI handoff slices, image healthcheck metadata, restart policy create/runtime slices, and restart policy timing support |
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
14. The health status slab aligns with [`apple/container#1502`](https://github.com/apple/container/issues/1502) and [`apple/container#1504`](https://github.com/apple/container/pull/1504), then adds `HealthStatus`, `ContainerSnapshot.health`, `ContainerHealthCheck`, `ContainerConfiguration.healthCheck`, and runtime health observation through separate local fork handoffs.
15. The healthcheck CLI slab adds Docker-style `container run/create --health-*` and `--no-healthcheck` flags. Its handoff files are `ISSUE-healthcheck-cli.md` and `PR-healthcheck-cli.md` in the container fork.
16. The restart-policy create-options slab adds `ContainerRestartPolicy`, `ContainerCreateOptions.restartPolicy`, Docker-style `container run/create --restart` parsing, and `--rm` conflict validation. Its handoff files are `ISSUE-restart-policy-create-options.md` and `PR-restart-policy-create-options.md` in the container fork.
17. The restart-policy runtime slab adds fork-owned restart scheduling for `no`, `always`, `unless-stopped`, and `on-failure[:max-retries]`. Its handoff files are `ISSUE-restart-policy-runtime.md` and `PR-restart-policy-runtime.md` in the container fork.
18. The deploy restart-policy plugin slab normalizes Compose Deploy `restart_policy`, gives it precedence over service-level `restart`, and maps `condition` plus `max_attempts` where the fork-backed restart runtime can express it. Its handoff files are `ISSUE-deploy-restart-policy.md` and `PR-deploy-restart-policy.md`.
19. The restart-policy timing slab adds fork-owned `ContainerRestartPolicy` timing fields for retry delay and successful-run window, then maps Compose Deploy `delay` and `window` through the plugin. Its container handoff files are `ISSUE-restart-policy-timing.md` and `PR-restart-policy-timing.md`.
20. The image healthcheck metadata slab references [`apple/container#440`](https://github.com/apple/container/issues/440), [`apple/container#1502`](https://github.com/apple/container/issues/1502), and [`apple/container#1504`](https://github.com/apple/container/pull/1504), then exposes Docker image config `Healthcheck` metadata through `ImageResource.Variant.healthCheck` on the fork. Its container handoff files are `ISSUE-image-healthcheck-metadata.md` and `PR-image-healthcheck-metadata.md`.
21. The image healthcheck inheritance plugin slab reads that direct API metadata so Dockerfile `HEALTHCHECK` defaults and timing-only Compose overrides can become runtime `--health-*` flags. Its handoff files are `ISSUE-image-healthcheck-inheritance.md` and `PR-image-healthcheck-inheritance.md`.
22. The config/secret materialization plugin slab follows Docker's Compose config and secret source model by materializing `configs.content`, `configs.environment`, and `secrets.environment` into deterministic project-scoped files under the per-user `container-compose` state root, then mounts them read-only through existing `apple/container` bind-mount primitives. Its handoff files are `ISSUE-config-secret-materialization.md` and `PR-config-secret-materialization.md`.

## Docker/Compose Reference Targets

- Docker Compose `logs` documents `--follow`, `--index`, `--no-color`, `--no-log-prefix`, `--since`, `--tail`, `--timestamps`, and `--until`: [docker compose logs](https://docs.docker.com/reference/cli/docker/compose/logs/).
- Compose service `logging` documents `driver` plus driver-specific `options`: [Compose services logging](https://docs.docker.com/reference/compose-file/services/#logging).
- Docker `json-file` logging documents `max-size` and `max-file`: [JSON file logging driver](https://docs.docker.com/engine/logging/drivers/json-file/).
- Docker `local` logging documents rotated local retained log storage: [Local file logging driver](https://docs.docker.com/engine/logging/drivers/local/).
- Compose Deploy `restart_policy` documents `condition`, `delay`, `max_attempts`, and `window`, with `restart` as the fallback when deploy policy is absent: [Compose deploy restart_policy](https://docs.docker.com/reference/compose-file/deploy/#restart_policy).
- Compose service `restart` documents the container-level values that the fork-backed runtime can express: [Compose services restart](https://docs.docker.com/reference/compose-file/services/#restart).
- Dockerfile `HEALTHCHECK` documents image-level probe metadata that Docker Compose inherits unless a service overrides or disables it: [Dockerfile HEALTHCHECK](https://docs.docker.com/reference/dockerfile/#healthcheck).
- Compose configs document `file`, `environment`, `content`, and `external` sources plus default `0444` permissions: [Compose configs](https://docs.docker.com/reference/compose-file/configs/).
- Compose secrets document `file` and `environment` sources for Docker Compose local workflows: [Compose secrets](https://docs.docker.com/reference/compose-file/secrets/).

## What Belongs Where

| Behavior | Owner |
| --- | --- |
| Runtime log storage, replay filters, rotated replay, cursor semantics, persisted logging policy | `apple/container` or the `stephenlclarke/container` fork while upstreaming |
| Compose service selection, replica fan-out, `--index`, prefixes, colors, `--no-log-prefix`, command formatting | `container-compose` |
| Compose file merge, interpolation, profiles, includes, extensions | `compose-go` normalizer helper |
| Docker output parity fixtures and local comparison harnesses | `container-compose`, with runtime assertions mirrored in `container` tests when the primitive is runtime-owned |

## Active Slab

Lifecycle dependency and file-source support across the container fork and compose plugin, covering `service_completed_successfully`, stopped-container `wait` replay, explicit service healthchecks, `service_healthy`, service-level `restart`, deploy restart policy timing, Dockerfile-inherited healthchecks, and plugin-side runtime config/secret materialization.

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
- Added local `apple/container` health status, healthcheck configuration, runtime observer, and Docker-style CLI flag slices so explicit Compose service healthchecks can reach the runtime without Compose-specific code in `apple/container`.
- Projected runtime health through `ComposeContainerSummary`.
- Implemented explicit Compose `healthcheck` mapping to `container run/create --health-*` and `--no-healthcheck` flags.
- Implemented Dockerfile-inherited image healthcheck mapping and timing-only Compose healthcheck overrides when the fork exposes image `HEALTHCHECK` metadata through the direct image API.
- Implemented `depends_on.condition: service_healthy`, including `starting` polling, `healthy` success, `unhealthy` failure, and clear rejection when a dependency has no runtime health status.
- Added fork-side Docker-compatible `container run/create --restart` create options and restart scheduling for service containers.
- Implemented service-level Compose `restart` mapping to `container run --restart` for service containers. One-off `compose run` containers intentionally do not inherit service restart policy.
- Added structured normalizer output for `deploy.restart_policy`, mapped deploy `condition` and `max_attempts` to the fork-backed `--restart` surface, and kept deploy restart policy ahead of service-level `restart` per Docker Compose semantics.
- Added fork-side restart policy timing fields and mapped `deploy.restart_policy.delay` / `window` to the integration timing flags for service containers.
- Added deterministic plugin-side materialization for runtime `configs.content`, `configs.environment`, and `secrets.environment` grants, including read-only mount rendering, secret/config file modes, no-write dry-run behavior, and project cleanup during `down`.

Next:

- Continue the lifecycle topic with remaining job-mode and external config/secret-store gaps, or move to the next highest-value Compose surface that has matching fork/runtime primitives.
- Keep Dockerfile-inherited healthchecks marked fork-backed until equivalent image config parsing and `ImageResource` metadata are accepted upstream.
- Keep the log comparison fixtures as a parallel backlog item, but do not switch away from the lifecycle topic until health/restart are implemented or blocked.

## Open Blockers

- `apple/container` has not accepted the retrieval parser stack yet, so released `container-compose` branches must still distinguish upstream support from fork-only support.
- `apple/container` still needs an accepted raw rotation-aware follow stream before released `container-compose` can rely on that runtime stream without depending on the fork.
- `apple/container` still needs an accepted structured rotation-aware follow stream before released `container-compose` can rely on `ContainerClient.followLogRecords(id:options:)` without depending on the fork.
- Remote logging drivers and driver-specific metadata remain runtime gaps; local `json-file`, `local`, `none`, `max-size`, and `max-file` stay fork-only until upstream runtime policy lands.
- `apple/container` still needs accepted exit metadata before released `container-compose` can rely on stopped-container `wait` replay or `service_completed_successfully` without depending on the fork.
- `apple/container` still needs accepted health status, healthcheck configuration, health observation, and CLI/direct creation support before released `container-compose` can rely on explicit service healthchecks or `service_healthy` without depending on the fork.
- `apple/container` still needs accepted image-config parsing for Dockerfile-inherited `HEALTHCHECK` metadata before released `container-compose` can tune image healthchecks without declaring `healthcheck.test`.
- `apple/container` still needs accepted restart-policy create/runtime primitives before released `container-compose` branches can rely on service-level `restart` without depending on the fork.
- Released upstream `apple/container` still needs accepted restart-policy create/runtime/timing primitives before released `container-compose` branches can rely on service-level `restart` or `deploy.restart_policy` without depending on the fork.
- `apple/container` still needs a first-class config/secret store, or equivalent lookup primitive, before external Compose `configs` and `secrets` can be represented without local bind-mount materialization.

## Checkpoint Format

End each slice with:

- Done: what changed.
- Changed: repo, branch, commit.
- Validated: exact commands and results.
- Blocked: remaining upstream/runtime/plugin blockers.
- Next: the smallest useful follow-up.
