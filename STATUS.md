# Mission Control

Last updated: 2026-06-22 07:52 BST.

This file is the first stop before starting a `container-compose` capability slice. It keeps the runtime fork, upstream `apple/container` work, Docker Compose target behavior, and plugin branch state in one place so the active plan is not held in memory.

## Current Objective

Complete Docker Compose v2 local-development behavior where `apple/container` can expose matching runtime primitives. The log slabs retargeted raw `container-compose logs --follow` to `ContainerClient.followLogs(id:options:)` and structured/timestamped followed logs to `ContainerClient.followLogRecords(id:options:)` on the forked runtime, so the plugin no longer polls merged snapshots or active record files while following. The active lifecycle/config/network/runtime-controls slab now uses fork-backed `ContainerSnapshot.exitCode` metadata for stopped-container `wait` replay, `depends_on.condition: service_completed_successfully`, local `deploy.mode: replicated-job` / `global-job`, explicit service healthchecks, Dockerfile-inherited image healthchecks, `depends_on.condition: service_healthy`, service-level `restart`, fork-backed `deploy.restart_policy` mode/retry/timing support, plugin-side materialization for Docker Compose runtime configs/secrets that can be represented as read-only local file mounts, fork-backed static `extra_hosts` mappings including `host-gateway`, fork-backed Compose `hostname` and `domainname` mapping, fork-backed single-network Compose alias mapping, the safe explicit-single-network `links` subset, the safe single-shared-runtime-network `external_links` subset, Compose `blkio_config` normalization/mapping to the active `apple/container#1595` `--blkio` runtime contract, and Compose `sysctls` mapping to the fork-backed `container run/create --sysctl` runtime bridge.

## Branch Map

| Repository | Branch | Purpose | Current state |
| --- | --- | --- | --- |
| `stephenlclarke/container-compose` | `logs-integration` | Compose-side proving branch for log and lifecycle behavior against the forked runtime | Active local worktree with Docker rotated-tail fixture updates, raw follow retargeting to `ContainerClient.followLogs(id:options:)`, structured follow retargeting to `ContainerClient.followLogRecords(id:options:)`, stopped-container `wait` replay, `service_completed_successfully`, local deploy job modes, explicit and Dockerfile-inherited healthcheck flag mapping, `service_healthy` dependency gates, service `restart` mapping, `deploy.restart_policy` condition/max-attempt/timing mapping, local materialization for runtime `configs.content`, `configs.environment`, and `secrets.environment` grants, generated grant mode handling, static and `host-gateway` `extra_hosts` mapping, service `hostname` and `domainname` mapping, single-network service alias mapping, the explicit-single-network `links` subset, the single-shared-runtime-network `external_links` subset, `blkio_config` mapping to the `--blkio` runtime contract from [apple/container#1595](https://github.com/apple/container/pull/1595), and service `sysctls` mapping to fork-backed `--sysctl` arguments. The branch now pins to `stephenlclarke/containerization@integration/blkio-runtime` through the local runtime stack so [apple/containerization#739](https://github.com/apple/containerization/pull/739) can be tested before upstream merge. |
| `stephenlclarke/container` | `logs-integration-chris` | Fork integration branch layered around Chris George's log retrieval direction plus lifecycle primitives needed by Compose | Active local worktree with static rotated tail, policy model, disabled-capture, local driver/options, writer rotation, raw rotation-aware follow, structured rotation-aware follow handoff files, the #1562 exit-metadata cherry-pick, health status/configuration/observer/CLI handoff slices, image healthcheck metadata, restart policy create/runtime slices, restart policy timing support, explicit host entries, explicit host-gateway resolution, explicit container hostnames, explicit container domain names, single-network attachment aliases, and repeatable `container run/create --sysctl` |
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
23. The config/secret grant mode plugin slab applies service-level `mode` to generated config/secret grants, ignores writable bits per Compose semantics, preserves Docker Compose bind-mount behavior for file-backed grants, and keeps `uid`/`gid` ownership remapping as an apple/container runtime gap. Its handoff files are `ISSUE-config-secret-grant-mode.md` and `PR-config-secret-grant-mode.md`.
24. The host-entry runtime slab combines the directions from [apple/container#1340](https://github.com/apple/container/pull/1340) and [apple/container#1563](https://github.com/apple/container/pull/1563), adding typed `ContainerConfiguration.HostEntry`, repeatable `--add-host`, and runtime `/etc/hosts` injection in the fork. Its container handoff files are `ISSUE-host-entries.md` and `PR-host-entries.md`.
25. The Compose `extra_hosts` plugin slab maps compose-go normalized static host entries to `container run/create --add-host` and validates IP literals before side effects. Its handoff files are `ISSUE-extra-hosts.md` and `PR-extra-hosts.md`.
26. The hostname runtime/plugin slab adds fork-side `container run/create -h, --hostname`, preserves existing default hostname derivation, and maps Compose service `hostname` to the runtime. Its handoff files are `ISSUE-hostname.md` and `PR-hostname.md` in the container fork, plus `ISSUE-service-hostname.md` and `PR-service-hostname.md` in this repository.
27. The host-gateway runtime/plugin slab adds fork-side `container run/create --add-host host:host-gateway` resolution to the first network IPv4 gateway and maps Compose `extra_hosts` `host-gateway` entries to that runtime primitive. Its handoff files are `ISSUE-host-gateway.md` and `PR-host-gateway.md` in both repositories.
28. The network-alias runtime/plugin slab adds fork-side `AttachmentOptions.aliases` plus `container run/create --network name,alias=...`, then maps Compose `services.*.networks.*.aliases` for the current single-network subset. Its handoff files are `ISSUE-network-aliases.md` and `PR-network-aliases.md` in both repositories.
29. The legacy-links plugin slab maps Compose `links` to implicit dependency ordering plus target-service aliases for services that share exactly one Compose network, including the compose-go normalized implicit `default` network. Its handoff files are `ISSUE-links.md` and `PR-links.md` in this repository.
30. The domainname runtime/plugin slab adds fork-side `ContainerConfiguration.domainname`, `container run/create --domainname`, runtime `kernel.domainname` mapping, and Compose service `domainname` translation. Its handoff files are `ISSUE-domainname.md` and `PR-domainname.md` in the container fork, plus `ISSUE-service-domainname.md` and `PR-service-domainname.md` in this repository.
31. The legacy external-links plugin slab maps Compose `external_links` to generated `--add-host` entries when the source service has exactly one Compose network and the referenced existing apple/container container has exactly one matching runtime attachment. Its handoff files are `ISSUE-external-links.md` and `PR-external-links.md` in this repository.
32. The deploy job-mode plugin slab preserves compose-go normalized `deploy.mode: replicated-job` / `global-job`, starts local job replicas detached, waits for successful completion through the direct lifecycle adapter, and treats job `condition: any` as `on-failure`. Its handoff files are `ISSUE-deploy-job-modes.md` and `PR-deploy-job-modes.md` in this repository.
33. The block I/O plugin slab preserves Compose `blkio_config` fields and maps them to the repeatable `container run/create --blkio` key-value contract proposed by Chris George in [apple/container#1595](https://github.com/apple/container/pull/1595), which closes [apple/container#1512](https://github.com/apple/container/issues/1512). Its handoff files are `ISSUE-blkio-config.md` and `PR-blkio-config.md` in this repository.
34. The sysctl runtime/plugin slab exposes the existing fork-side `ContainerConfiguration.sysctls` through repeatable `container run/create --sysctl name=value`, then maps Compose service `sysctls` to that runtime bridge. Its handoff files are `ISSUE-sysctl-cli.md` and `PR-sysctl-cli.md` in the container fork, plus `ISSUE-sysctls.md` and `PR-sysctls.md` in this repository.

## Docker/Compose Reference Targets

- Docker Compose `logs` documents `--follow`, `--index`, `--no-color`, `--no-log-prefix`, `--since`, `--tail`, `--timestamps`, and `--until`: [docker compose logs](https://docs.docker.com/reference/cli/docker/compose/logs/).
- Compose service `logging` documents `driver` plus driver-specific `options`: [Compose services logging](https://docs.docker.com/reference/compose-file/services/#logging).
- Docker `json-file` logging documents `max-size` and `max-file`: [JSON file logging driver](https://docs.docker.com/engine/logging/drivers/json-file/).
- Docker `local` logging documents rotated local retained log storage: [Local file logging driver](https://docs.docker.com/engine/logging/drivers/local/).
- Compose Deploy `restart_policy` documents `condition`, `delay`, `max_attempts`, and `window`, with `restart` as the fallback when deploy policy is absent: [Compose deploy restart_policy](https://docs.docker.com/reference/compose-file/deploy/#restart_policy).
- Compose Deploy job modes document `replicated-job` and `global-job` as completion-oriented services that leave completed tasks until explicit removal: [Compose deploy mode](https://docs.docker.com/reference/compose-file/deploy/#mode).
- Compose service `restart` documents the container-level values that the fork-backed runtime can express: [Compose services restart](https://docs.docker.com/reference/compose-file/services/#restart).
- Dockerfile `HEALTHCHECK` documents image-level probe metadata that Docker Compose inherits unless a service overrides or disables it: [Dockerfile HEALTHCHECK](https://docs.docker.com/reference/dockerfile/#healthcheck).
- Compose configs document `file`, `environment`, `content`, and `external` sources plus default `0444` permissions: [Compose configs](https://docs.docker.com/reference/compose-file/configs/).
- Compose secrets document `file` and `environment` sources for Docker Compose local workflows: [Compose secrets](https://docs.docker.com/reference/compose-file/secrets/).
- Compose service `extra_hosts` documents static host-to-IP entries using `HOST=IP`, `HOST:IP`, bracketed IPv6, and mapping syntax: [Compose extra_hosts](https://docs.docker.com/reference/compose-file/services/#extra_hosts).
- Compose service `hostname` documents custom service hostnames, and Docker exposes the matching runtime primitive through `docker container run --hostname`: [Compose hostname](https://docs.docker.com/reference/compose-file/services/#hostname), [Docker run hostname](https://docs.docker.com/reference/cli/docker/container/run/).
- Compose service `domainname` documents custom service NIS domain names, and Docker exposes the matching runtime primitive through `docker container run --domainname`: [Compose domainname](https://docs.docker.com/reference/compose-file/services/#domainname), [Docker run domainname](https://docs.docker.com/reference/cli/docker/container/run/).
- Compose service network `aliases` documents network-scoped alternative service hostnames, and Docker exposes the matching runtime primitive through `docker network connect --alias`: [Compose aliases](https://docs.docker.com/reference/compose-file/services/#aliases), [Docker network connect alias](https://docs.docker.com/reference/cli/docker/network/connect/).
- Compose service `links` documents legacy service references as alias-capable links plus implicit dependencies: [Compose links](https://docs.docker.com/reference/compose-file/services/#links).
- Compose service `external_links` documents links to services managed outside the Compose application with optional `SERVICE:ALIAS` syntax: [Compose external_links](https://docs.docker.com/reference/compose-file/services/#external_links).
- Compose service `blkio_config` documents block I/O weight and throttle settings, and [apple/container#1595](https://github.com/apple/container/pull/1595) proposes the matching `--blkio` runtime flag: [Compose blkio_config](https://docs.docker.com/reference/compose-file/services/#blkio_config).
- Compose service `sysctls` documents namespaced kernel parameters, and Docker exposes the matching runtime primitive through `docker container run --sysctl`: [Compose sysctls](https://docs.docker.com/reference/compose-file/services/#sysctls), [Docker run sysctl](https://docs.docker.com/reference/cli/docker/container/run/#sysctl).

## What Belongs Where

| Behavior | Owner |
| --- | --- |
| Runtime log storage, replay filters, rotated replay, cursor semantics, persisted logging policy | `apple/container` or the `stephenlclarke/container` fork while upstreaming |
| Compose service selection, replica fan-out, `--index`, prefixes, colors, `--no-log-prefix`, command formatting | `container-compose` |
| Compose file merge, interpolation, profiles, includes, extensions | `compose-go` normalizer helper |
| Docker output parity fixtures and local comparison harnesses | `container-compose`, with runtime assertions mirrored in `container` tests when the primitive is runtime-owned |

## Active Slab

Lifecycle dependency, file-source support, networking identity, and targeted runtime-control support across the container fork and compose plugin, covering `service_completed_successfully`, stopped-container `wait` replay, explicit service healthchecks, `service_healthy`, service-level `restart`, deploy restart policy timing, Dockerfile-inherited healthchecks, plugin-side runtime config/secret materialization, safe links/external links, `blkio_config` mapping where the runtime exposes Chris George's #1595 `--blkio` contract, and `sysctls` mapping where the runtime exposes repeatable `--sysctl`.

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
- Added generated config/secret grant `mode` support, including octal parsing, write-bit stripping, permission-aware materialized paths for recreate hashes, and clear `uid`/`gid` ownership-remapping rejection.
- Added fork-side explicit host entries and plugin-side Compose `extra_hosts` mapping for static IP literals, including `HOST=IP`, `HOST:IP`, and bracketed IPv6 forms.
- Added fork-side explicit container hostname support and plugin-side Compose `hostname` mapping for service containers and one-off `run` containers.
- Added fork-side Docker `host-gateway` resolution and plugin-side Compose `extra_hosts` mapping for `host.docker.internal:host-gateway`.
- Added fork-side network attachment aliases and plugin-side Compose `networks.<name>.aliases` mapping for the current single-network local subset.
- Added plugin-side legacy `links` mapping for the explicit-single-network local subset, including implicit dependency ordering, target-service alias projection, and early rejection for projected link aliases that collide with another service alias or for links missing explicit shared networks.
- Added fork-side explicit container domain-name support and plugin-side Compose `domainname` mapping for service containers and one-off `run` containers.
- Added plugin-side legacy `external_links` mapping for the single-shared-runtime-network local subset, including direct external container inspection, generated host-entry rendering, recreate hashing for resolved external IPs, and early rejection for missing or ambiguous external containers.
- Added plugin-side deploy job-mode support for the fork-backed branch, including compose-go `deployMode` preservation, detached job replica starts, direct wait for successful completion, non-zero exit failure before later services start, and Docker-compatible job restart-policy handling for `condition: any`.
- Added plugin-side `blkio_config` support by preserving compose-go normalized weights and throttle devices and rendering `--blkio weight=...` / `--blkio device=...,read-bps=...` arguments for service containers, `create`, and one-off `run` once the runtime exposes [apple/container#1595](https://github.com/apple/container/pull/1595).
- Added fork-side `container run/create --sysctl name=value` and plugin-side Compose service `sysctls` mapping for service containers, `create`, and one-off `run`.

Next:

- Continue the lifecycle/network/runtime-control topic with remaining external config/secret-store, multi-network DNS/alias behavior, shared alias gaps, or the next high-value Compose surface that has matching fork/runtime primitives.
- Keep Dockerfile-inherited healthchecks marked fork-backed until equivalent image config parsing and `ImageResource` metadata are accepted upstream.
- Keep the log comparison fixtures as a parallel backlog item, but do not switch away from the lifecycle topic until health/restart are implemented or blocked.

## Open Blockers

- `apple/container` has not accepted the retrieval parser stack yet, so released `container-compose` branches must still distinguish upstream support from fork-only support.
- `apple/container` still needs an accepted raw rotation-aware follow stream before released `container-compose` can rely on that runtime stream without depending on the fork.
- `apple/container` still needs an accepted structured rotation-aware follow stream before released `container-compose` can rely on `ContainerClient.followLogRecords(id:options:)` without depending on the fork.
- Remote logging drivers and driver-specific metadata remain runtime gaps; local `json-file`, `local`, `none`, `max-size`, and `max-file` stay fork-only until upstream runtime policy lands.
- `apple/container` still needs accepted exit metadata before released `container-compose` can rely on stopped-container `wait` replay or `service_completed_successfully` without depending on the fork.
- `apple/container` still needs accepted exit metadata before released `container-compose` can rely on local deploy job-mode completion without depending on the fork.
- `apple/container` still needs accepted health status, healthcheck configuration, health observation, and CLI/direct creation support before released `container-compose` can rely on explicit service healthchecks or `service_healthy` without depending on the fork.
- `apple/container` still needs accepted image-config parsing for Dockerfile-inherited `HEALTHCHECK` metadata before released `container-compose` can tune image healthchecks without declaring `healthcheck.test`.
- `apple/container` still needs accepted restart-policy create/runtime primitives before released `container-compose` branches can rely on service-level `restart` without depending on the fork.
- Released upstream `apple/container` still needs accepted restart-policy create/runtime/timing primitives before released `container-compose` branches can rely on service-level `restart` or `deploy.restart_policy` without depending on the fork.
- `apple/container` still needs a first-class config/secret store, or equivalent lookup primitive, before external Compose `configs` and `secrets` can be represented without local bind-mount materialization.
- `apple/container` still needs config/secret ownership remapping before `uid`/`gid` on generated Compose grants can match Docker Compose's environment-backed secret behavior.
- `apple/container` still needs accepted explicit host-entry support before released `container-compose` branches can rely on static `extra_hosts` without depending on the fork.
- `apple/container` still needs accepted host-gateway resolution before released `container-compose` branches can rely on Docker `host-gateway` extra-host values without depending on the fork.
- `apple/container` still needs accepted explicit hostname and domain-name support before released `container-compose` branches can rely on Compose `hostname` or `domainname` without depending on the fork.
- `apple/container` still needs accepted network attachment alias support before released `container-compose` branches can rely on single-network Compose aliases without depending on the fork.
- `apple/container` still needs multi-network attach/connect and source-network-aware DNS before released `container-compose` can support aliases on multi-network services, Docker-compatible shared alias resolution, or full legacy-link behavior.
- `apple/container` still needs accepted source-scoped DNS and default service-name alias behavior before released `container-compose` can support Docker-compatible multi-network links, shared aliases, and full `external_links` behavior without depending on single-network alias projection or generated host entries.
- Released-Apple compatibility still needs accepted block I/O runtime support from [apple/container#1595](https://github.com/apple/container/pull/1595) and the matching `containerization` blockIO runtime API from [apple/containerization#739](https://github.com/apple/containerization/pull/739). The local integration stack is pinned to `stephenlclarke/containerization@integration/blkio-runtime` so `blkio_config` can be tested before those upstream merges land.
- Released-Apple compatibility still needs accepted `container run/create --sysctl` support before released `container-compose` branches can rely on Compose service `sysctls` without depending on the fork.

## Checkpoint Format

End each slice with:

- Done: what changed.
- Changed: repo, branch, commit.
- Validated: exact commands and results.
- Blocked: remaining upstream/runtime/plugin blockers.
- Next: the smallest useful follow-up.
