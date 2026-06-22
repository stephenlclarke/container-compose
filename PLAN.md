# container-compose Log Compliance Plan

This plan tracks the log-related work needed for `container-compose` to match Docker Compose v2 local-development behavior where [`apple/container`](https://github.com/apple/container) exposes equivalent runtime primitives.

Assessment timestamp: `2026-06-21 23:43:58 BST`.

Mission-control state for the active branch, runtime dependency chain, and next work item is tracked in [STATUS.md](STATUS.md). Use that file as the handoff entry point before starting another log or Compose capability slice.

## Scope

This file is intentionally narrower than the earlier whole-project backlog. It covers Docker Compose v2 log behavior across:

- `docker compose logs [OPTIONS] [SERVICE...]`
- `docker compose attach` behavior that is implemented through log streaming in this repository
- Compose service `logging` configuration
- Runtime log data exposed by [`apple/container`](https://github.com/apple/container)

Docker Compose currently documents `logs` with `--follow`, `--index`, `--no-color`, `--no-log-prefix`, `--since`, `--tail/-n`, `--timestamps/-t`, and `--until`. The Compose file reference documents service-level `logging.driver` and `logging.options`.

## Status Lozenges

- <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">: supported by both [`apple/container`](https://github.com/apple/container) and `container-compose` for the Compose behavior described.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">: one side has a useful primitive or partial mapping, but Docker Compose v2 behavior is not complete yet.
- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square">: [`apple/container`](https://github.com/apple/container) appears to expose enough runtime data, but `container-compose` still needs implementation work.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">: the first missing piece is an [`apple/container`](https://github.com/apple/container) runtime, log-storage, or logging-policy primitive.
- <img alt="OUTSTANDING" src="https://img.shields.io/badge/OUTSTANDING-6B7280?style=flat-square">: not started or not yet broken down into a concrete implementation path.

## Cross-Implementation Lozenges

- <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square">: scan marker for any item that overlaps with or complements another Compose implementation.
- <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square">: this work overlaps with or complements another Compose implementation and should stay visible during upstream planning.
- <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square">: another Compose implementation is working in the same problem area and should be reviewed before upstreaming.
- <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square">: this repository adds a compatible piece, different architecture boundary, or upstreamable slice that can help the other implementation.

The cross-implementation lozenges are intentionally separate from the support-status traffic lights. Blue <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> is the top-level marker for anything that overlaps with or complements another Compose implementation. Rose <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> keeps the existing scan-friendly peer touchpoint marker. Cyan <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> marks direct overlap that needs comparison before upstreaming. Purple <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> marks complementary work that can help another implementation without necessarily solving the same layer. A work item can carry both detail lozenges when it both intersects peer code and contributes a reusable compatibility boundary, fixture, or apple/container API slice.

## Current Runtime Evidence

`container-compose` currently calls `ContainerClient.logs(id:options:replay:)` through `ContainerClientLogManager` for static raw replay, calls `ContainerClient.followLogs(id:options:)` for raw followed logs, and calls `ContainerClient.followLogRecords(id:options:)` for followed structured/timestamped logs on the local integration stack. Static raw replay passes `tail` and rotated replay requests to apple/container where available. Static timestamped output and time-window rendering pass `tail`, `--since`, and `--until` to `ContainerClient.logRecords(id:options:replay:)`, then render the returned structured records locally. The local apple/container branch now applies structured replay and follow filters after logical log-line reconstruction, including split records, chunked records, final complete EOF records, retained `stdio.jsonl` replay, and active-file rotation. The extracted `logs-structured-record-api` branch exposes the active-file upstream surfaces as `ContainerClient.logRecords(id:options:)`, `ContainerClient.logRecordFile(id:)`, `ContainerLogRecord`, `ContainerLogOptions.tail/since/until`, XPC routes `containerLogRecords` and `containerLogRecordFile`, active raw bytes in `stdio.log`, and active structured JSON Lines records in `stdio.jsonl`. The local apple/container integration branch now also exposes `ContainerClient.followLogs(id:options:)` for raw stdio follow and `ContainerClient.followLogRecords(id:options:)` for structured/timestamped follow across rename-based local rotation. `container-compose` keeps Compose-specific service fan-out, prefix/color formatting, line reconstruction, and container-stop flushing in the plugin.

[`apple/container`](https://github.com/apple/container) currently exposes `container logs [--boot] [--follow] [-n <n>] <container-id>` and `ContainerClient.logs(id:)` upstream. The local [`stephenlclarke/container` `logs-integration-chris`](https://github.com/stephenlclarke/container/tree/logs-integration-chris) branch is linear from upstream `main`, starts with Chris George's [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11) / [`apple/container#1592`](https://github.com/apple/container/pull/1592) retrieval-options direction, then tightens the API boundary by keeping `ContainerLogOptions` focused on retrieval filters, `ContainerLogReplayOptions` focused on rotated replay policy, and timestamp rendering as command/plugin presentation. The branch layers tail/until, static filtered replay, byte-preserving raw log tail filtering, Docker-compatible timestamp parsing, Docker-like line-framed structured log storage, `ContainerClient.logRecords(id:options:replay:)` with line-correct tail/since/until filtering, `ContainerClient.logRecordFile(id:)`, writer-level local log rotation for configured max size and file count, `container create/run --log-opt max-size=<size>` and `--log-opt max-file=<count>` local rotation policy parsing, static rotated raw and structured replay, raw rotation-aware follow through `ContainerClient.followLogs(id:options:)`, structured rotation-aware follow through `ContainerClient.followLogRecords(id:options:)`, static `container logs --timestamps` CLI rendering, and followed `container logs --follow --timestamps/--since/--until` CLI rendering from structured record streams. It is an integration proving branch, not the intended upstream PR shape.

## apple/container Log Direction

The container-side log work should be proposed upstream as small, reviewable PRs rather than as the full local integration branch. The intended sequence is:

1. Preserve Chris George's log retrieval direction from [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11) and [`apple/container#1592`](https://github.com/apple/container/pull/1592), while keeping retrieval filters, replay policy, and presentation flags on separate API boundaries.
2. Add `tail`, `since`, and `until` behavior only where apple/container can honor Docker's line-based contract after logical record reconstruction, with tests for split records, chunked records, final complete EOF records, and legacy raw records.
3. Add Docker-compatible timestamp parsing for RFC 3339/RFC 3339 nano, Unix seconds with optional fractional seconds, and relative durations.
4. Add structured log records and record-file replay with byte-fidelity, stdout/stderr identity, final-record EOF handling, and line-boundary tests.
5. Add static rotated raw and structured replay for local file-backed logging.
6. Add local logging policy support for `json-file`, `local`, `none`, `max-size`, and `max-file` separately from any future remote logging drivers.
7. Add writer-level local rotation so `max-size` and `max-file` affect raw and structured persisted logs in the runtime writer.
8. Add a bounded rotation-aware raw follow cursor or stream so `container-compose` does not need plugin-side merged-snapshot polling for raw stdio logs.
9. Add rotation-aware structured/timestamped follow over `stdio.jsonl`.
10. Update `container-compose` after each accepted apple/container primitive lands, keeping Compose-specific formatting, prefixing, fan-out, and service selection inside this repository.

## Current Slab: Rotation-Aware Log Follow

Assumption for this slab: Chris George's [`apple/container#1592`](https://github.com/apple/container/pull/1592) and the follow-up [`apple/container#1764`](https://github.com/apple/container/pull/1764) / [`apple/container#1765`](https://github.com/apple/container/pull/1765) changes merge upstream. Treat those as the baseline runtime contract for `ContainerClient.logs(id:options:)`, `tail`, `since`, `until`, and Docker-compatible timestamp parsing. The next work should not reopen those decisions unless upstream review changes the accepted API shape.

Why this slab now: Docker Compose documents `logs --follow` and `logs --tail` together. After static retained replay is line-correct, the next expensive plugin workaround is raw followed log polling across rename-based local rotation. The runtime should own that cursor so `container-compose` can fan out service output without repeatedly rebuilding retained snapshots.

Reference targets:

- Docker Compose CLI `logs`: [`docker compose logs`](https://docs.docker.com/reference/cli/docker/compose/logs/)
- Compose service `logging`: [`services.logging`](https://docs.docker.com/reference/compose-file/services/#logging)
- Docker `json-file` rotation options: [`json-file` logging driver](https://docs.docker.com/engine/logging/drivers/json-file/)
- Docker `local` retained log behavior: [`local` logging driver](https://docs.docker.com/engine/logging/drivers/local/)

Existing PRs and branches to leverage:

- <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> [`apple/container#1592`](https://github.com/apple/container/pull/1592): Chris George's base log retrieval-options API. Use this naming and API direction as the compatibility anchor.
- <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> [`apple/container#1764`](https://github.com/apple/container/pull/1764): tail and until retrieval filters. Use it as the baseline for line-based filter semantics.
- <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> [`apple/container#1765`](https://github.com/apple/container/pull/1765): Docker-compatible timestamp and duration parser. Use it as the shared parser for container CLI, runtime API, and `container-compose`.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> [`apple/container#1758`](https://github.com/apple/container/pull/1758): SwiftLog handler deprecation cleanup. Keep it as log-stack hygiene, but do not treat it as a Compose feature dependency.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> [`apple/container#440`](https://github.com/apple/container/issues/440): native builder/parser support for Dockerfile `HEALTHCHECK`. Keep this linked to image metadata inheritance because Compose needs either Dockerfile metadata from built images or an accepted runtime image model exposing the same probe data.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> [`apple/container#1502`](https://github.com/apple/container/issues/1502) and [`apple/container#1504`](https://github.com/apple/container/pull/1504): health status and snapshot API direction. These are the compatibility anchor for explicit healthcheck runtime state; the fork's image-healthcheck metadata slice complements them by exposing the image-level probe defaults Compose inherits.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> [`logs-structured-record-storage`](https://github.com/stephenlclarke/container/tree/logs-structured-record-storage) and [`logs-structured-record-api`](https://github.com/stephenlclarke/container/tree/logs-structured-record-api): PR-ready fork branches that add active structured log storage and active structured record retrieval. They expose `stdio.log`, `stdio.jsonl`, `ContainerLogRecord`, `ContainerClient.logRecords(id:options:)`, and `ContainerClient.logRecordFile(id:)`; the local integration branch now adds static rotated replay and structured rotation-aware follow as separate later upstream slices.
- <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11): the fork-side precursor to #1592. Continue comparing API names and behavior so the two Compose efforts converge rather than fork the log contract.
- <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> [`apple/container#1736`](https://github.com/apple/container/pull/1736): peer Compose implementation. Use it for examples, test ideas, and CLI expectation comparison only; do not move Compose-specific policy into apple/container runtime PRs.

## Adjacent Slab: Pause/Unpause Lifecycle Controls

This slab tracks the runtime lifecycle primitive needed by Docker Compose v2 `pause` and `unpause`.

Reference targets:

- Docker Compose CLI `pause`: [`docker compose pause`](https://docs.docker.com/reference/cli/docker/compose/pause/)
- Docker Compose CLI `unpause`: [`docker compose unpause`](https://docs.docker.com/reference/cli/docker/compose/unpause/)
- Docker container CLI `pause`: [`docker container pause`](https://docs.docker.com/reference/cli/docker/container/pause/)
- Docker container CLI `unpause`: [`docker container unpause`](https://docs.docker.com/reference/cli/docker/container/unpause/)

<table>
  <thead>
    <tr>
      <th>Task</th>
      <th>Added</th>
      <th>Started</th>
      <th>Completed</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Expose pause/resume in the containerization fork</td>
      <td>2026-06-22 08:12:00 BST</td>
      <td>2026-06-22 08:12:00 BST</td>
      <td>2026-06-22 08:22:00 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: [`stephenlclarke/containerization`](https://github.com/stephenlclarke/containerization) branch `integration/blkio-runtime` now exposes `LinuxContainer.pause()` and `LinuxContainer.resume()` as commit `e172174` (`feat(runtime): add linux container pause controls`). The implementation bridges existing VM pause/resume hooks and validates state transitions with focused `LinuxContainerTests`.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Add pause/unpause lifecycle APIs to the container fork</td>
      <td>2026-06-22 08:12:00 BST</td>
      <td>2026-06-22 08:22:00 BST</td>
      <td>2026-06-22 08:30:02 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: [`stephenlclarke/container`](https://github.com/stephenlclarke/container) branch `logs-integration-chris` now exposes `RuntimeStatus.paused`, runtime pause/resume routes, `ContainerClient.pause(id:)`, `ContainerClient.unpause(id:)`, and `container pause` / `container unpause` as signed commit `61a11f4` (`feat(runtime): add container pause controls`). Handoff files are `ISSUE-pause-unpause.md` and `PR-pause-unpause.md` in the container fork. Released upstream apple/container remains blocked until these surfaces are accepted.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Map Compose pause/unpause to direct lifecycle APIs</td>
      <td>2026-06-22 08:34:54 BST</td>
      <td>2026-06-22 08:34:54 BST</td>
      <td>2026-06-22 08:34:54 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now routes `container compose pause [SERVICE...]` and `container compose unpause [SERVICE...]` through `ContainerClientLifecycleManager`, preserving Compose service selection, replicas, custom `container_name`, and dry-run rendering. This support is fork-backed until the matching apple/container and apple/containerization primitives are accepted upstream.</td>
    </tr>
  </tbody>
</table>

## Runtime Data Slab: Copy Follow-Link And Archive

This slab closes the next narrow copy-command gaps after basic service-aware copy support. Docker defines `cp --follow-link` as source-path symlink dereferencing and `cp --archive` as preserving UID/GID information where possible. This work keeps those behaviors in the generic runtime copy API and lets `container-compose` pass them through without adding Compose-specific behavior to `apple/container`.

Reference targets:

- Docker Compose CLI `cp --follow-link`: [`docker compose cp`](https://docs.docker.com/reference/cli/docker/compose/cp/)
- Docker CLI `container cp --follow-link`: [`docker container cp`](https://docs.docker.com/reference/cli/docker/container/cp/)
- Docker Compose CLI `cp --archive`: [`docker compose cp`](https://docs.docker.com/reference/cli/docker/compose/cp/)
- Docker CLI `container cp --archive`: [`docker container cp`](https://docs.docker.com/reference/cli/docker/container/cp/)
- Local runtime handoffs: copy handoff files in `docs/upstream/copy/` where available, plus the current root-level handoff files in repos that have not yet moved older notes.

<table>
  <thead>
    <tr>
      <th>Task</th>
      <th>Added</th>
      <th>Started</th>
      <th>Completed</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-218739?style=flat-square"> Add copy follow-link to the containerization copy control plane</td>
      <td>2026-06-22 08:57:04 BST</td>
      <td>2026-06-22 08:57:04 BST</td>
      <td>2026-06-22 09:07:45 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: the forked `containerization` branch adds `CopyRequest.follow_symlink`, regenerates Swift protobuf bindings, adds defaulted `followSymlink` parameters to `Vminitd.copy`, `LinuxContainer.copyIn`, and `LinuxContainer.copyOut`, and resolves final guest source symlinks under the mounted rootfs for Docker-style `COPY_OUT` behavior.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-218739?style=flat-square"> Expose copy follow-link through the container fork</td>
      <td>2026-06-22 08:57:04 BST</td>
      <td>2026-06-22 08:57:04 BST</td>
      <td>2026-06-22 09:07:45 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: the forked `container` branch adds defaulted `followSymlink` direct API parameters, propagates the flag through API-server and runtime-plugin XPC, adds `container copy -L, --follow-link`, updates command docs, and keeps Compose-specific service lookup out of the runtime repository.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-218739?style=flat-square"> Map Compose `cp --follow-link` to direct copy APIs</td>
      <td>2026-06-22 08:57:04 BST</td>
      <td>2026-06-22 08:57:04 BST</td>
      <td>2026-06-22 09:07:45 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` maps `ComposeCopyOptions.followLink` to direct copy transfer options, renders `--follow-link` in dry-runs, and scopes service-to-service follow-link behavior to the source copy-out leg.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-218739?style=flat-square"> Add copy archive ownership metadata to the containerization copy control plane</td>
      <td>2026-06-22 09:29:41 BST</td>
      <td>2026-06-22 09:29:41 BST</td>
      <td>2026-06-22 09:29:41 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: the forked `containerization` branch adds `CopyRequest.preserve_ownership`, UID/GID request fields, UID/GID/mode response metadata, and raw single-file ownership application so archive mode has an explicit runtime contract instead of relying only on directory tar behavior.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-218739?style=flat-square"> Expose copy archive mode through the container fork</td>
      <td>2026-06-22 09:29:41 BST</td>
      <td>2026-06-22 09:29:41 BST</td>
      <td>2026-06-22 09:29:41 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: the forked `container` branch adds defaulted `preserveOwnership` direct API parameters, propagates the flag through API-server and runtime-plugin XPC, adds `container copy -a, --archive`, and updates command docs and parser tests.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-218739?style=flat-square"> Map Compose `cp --archive` to direct copy APIs</td>
      <td>2026-06-22 09:29:41 BST</td>
      <td>2026-06-22 09:29:41 BST</td>
      <td>2026-06-22 09:29:41 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` maps `ComposeCopyOptions.archive` to direct copy ownership preservation, renders `--archive` in dry-runs, and requests ownership preservation across both host-staging legs for service-to-service copies while keeping `--follow-link` source-only.</td>
    </tr>
  </tbody>
</table>

## Runtime Data Slab: Process Listing / Compose Top

This slab closes the first process-listing slice needed by Docker Compose v2 `top`. It intentionally starts with PID-only runtime data so the API remains small, while leaving Docker's richer process columns such as user, elapsed CPU time, command, and arguments as a later runtime metadata slice.

Reference targets:

- Docker Compose CLI `top`: [`docker compose top`](https://docs.docker.com/reference/cli/docker/compose/top/)
- Docker container CLI `top`: [`docker container top`](https://docs.docker.com/reference/cli/docker/container/top/)

<table>
  <thead>
    <tr>
      <th>Task</th>
      <th>Added</th>
      <th>Started</th>
      <th>Completed</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Expose PID process identifiers in the containerization fork</td>
      <td>2026-06-22 10:13 BST</td>
      <td>2026-06-22 10:13 BST</td>
      <td>2026-06-22 10:13 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `stephenlclarke/containerization` branch `integration/blkio-runtime` now exposes PID-only process identifiers through `ContainerProcesses`, VM agent, `vminitd`, `LinuxContainer`, `Cgroup2Manager`, and `ManagedContainer` as commits `d69f7e5` and `aaa143b`. The follow-up fix allows process listing for paused containers as well as started containers.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Expose process listing through the container fork</td>
      <td>2026-06-22 10:13 BST</td>
      <td>2026-06-22 10:13 BST</td>
      <td>2026-06-22 10:13 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `stephenlclarke/container` branch `logs-integration-chris` now exposes `ContainerClient.processes(id:)`, API/XPC/runtime routes, runtime Linux service wiring, and PID-only `container top &lt;container&gt;` table output as commit `14a3067`. Released upstream support remains blocked until an equivalent process-listing API is accepted.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map Compose `top` to fork-backed process listing</td>
      <td>2026-06-22 10:13 BST</td>
      <td>2026-06-22 10:13 BST</td>
      <td>2026-06-22 10:13 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` branch `logs-integration` now implements `container compose top [SERVICES...]` through service-container selection and direct `ContainerClient.processes(id:)` fan-out as commit `b44ba55`. The supported fork-backed shape is PID-only; full Docker process metadata remains a later runtime gap rather than Compose policy.</td>
    </tr>
  </tbody>
</table>

## Runtime Data Slab: Container Events / Compose Events

This slab starts the event-streaming path needed by Docker Compose v2 `events`. The first slice stays in `apple/container` and exposes a generic container lifecycle event primitive; the Compose mapping remains a separate plugin slice so project/service filtering and Docker Compose output policy do not leak into the Apple runtime PR.

Reference targets:

- Docker Compose CLI `events`: [`docker compose events`](https://docs.docker.com/reference/cli/docker/compose/events/)
- Docker engine CLI `events`: [`docker system events`](https://docs.docker.com/reference/cli/docker/system/events/)
- Upstream issue: [`apple/container#484`](https://github.com/apple/container/issues/484)

<table>
  <thead>
    <tr>
      <th>Task</th>
      <th>Added</th>
      <th>Started</th>
      <th>Completed</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Expose container lifecycle events through the container fork</td>
      <td>2026-06-22 10:30 BST</td>
      <td>2026-06-22 10:45 BST</td>
      <td>2026-06-22 11:13 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `stephenlclarke/container` branch `logs-integration-chris` now exposes `ContainerEvent`, `ContainerClient.events()`, API-service lifecycle event emission for create/start/stop/pause/unpause/delete, non-blocking event subscribers, and `container events` JSON Lines output as code commits `b71e4bb323e3` and `0da7890b2632`. The handoff docs are in container commits `48b763c` and `24dcfbc` and mirrored under `docs/upstream/events/` and `docs/upstream/apple-container/`. No `apple/containerization` change was needed for this first slice because the event source lives at the API-service lifecycle boundary. Released upstream support remains blocked until an equivalent event-stream API is accepted against [apple/container#484](https://github.com/apple/container/issues/484).</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map Compose `events --json [SERVICE...]` to fork-backed event stream</td>
      <td>2026-06-22 11:13 BST</td>
      <td>2026-06-22 11:20 BST</td>
      <td>2026-06-22 11:42 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` branch `logs-integration` now maps `container compose events --json [SERVICE...]` to the fork-backed `ContainerClient.events()` stream as code commit `113be38063ea`. The plugin keeps Docker Compose policy here: filter to Compose project/service labels, skip one-off containers, apply selected-service arguments, strip Compose-private attributes, and render JSON Lines fields `time`, `type`, `service`, `id`, `action`, and `attributes`. The slice deliberately requires `--json` and rejects `--since`/`--until` until the runtime event primitive has replay or timestamp filtering. Handoff docs are `docs/upstream/events/ISSUE-compose-events.md` and `docs/upstream/events/PR-compose-events.md`; the optional local-only Docker parity check is `make docker-compose-events-parity`. Do not include this mapping in the Apple runtime PR.</td>
    </tr>
    <tr>
      <td><img alt="TODO" src="https://img.shields.io/badge/TODO-616161?style=flat-square"> Add runtime event replay/time filters for `--since` / `--until`</td>
      <td>2026-06-22 11:56 BST</td>
      <td></td>
      <td></td>
    </tr>
    <tr>
      <td colspan="4">Notes: this is the next selected slice from the event slab. It should start as a narrow `apple/container` PR-shaped primitive before the plugin enables `container compose events --since` or `--until`. A targeted live search on 2026-06-22 for open `since` / `until` / replay event issues and PRs found no matching open work in `apple/container` or `apple/containerization`, so the slice should reference [apple/container#484](https://github.com/apple/container/issues/484) plus Docker `system events` / Compose `events` behavior rather than stack on an existing Apple PR. Keep non-JSON Compose formatting separate as a plugin-only follow-up.</td>
    </tr>
  </tbody>
</table>

## Adjacent Slab: Exit Metadata And Completed Dependencies

This slab tracks the first non-log lifecycle capability needed by real Compose projects: `depends_on.condition: service_completed_successfully` and stopped-container `wait` replay. It intentionally reuses existing upstream work rather than inventing a new runtime contract.

Reference targets:

- Compose file `depends_on.condition`: [`depends_on`](https://docs.docker.com/reference/compose-file/services/#depends_on)
- Docker Compose CLI `wait`: [`docker compose wait`](https://docs.docker.com/reference/cli/docker/compose/wait/)
- Upstream issue: [`apple/container#1501`](https://github.com/apple/container/issues/1501)
- Upstream PR leveraged locally: [`apple/container#1562`](https://github.com/apple/container/pull/1562)

<table>
  <thead>
    <tr>
      <th>Task</th>
      <th>Added</th>
      <th>Started</th>
      <th>Completed</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Cherry-pick upstream exit metadata into the container fork</td>
      <td>2026-06-22 00:48:00 BST</td>
      <td>2026-06-22 00:48:00 BST</td>
      <td>2026-06-22 00:56:18 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: cherry-picked and adapted [`apple/container#1562`](https://github.com/apple/container/pull/1562) onto `stephenlclarke/container` branch `logs-integration-chris` as signed commit `9b6f743` (`feat(api): expose container exit metadata`). The local adaptation preserves Martín Fernández as author, keeps the #1501/#1562 provenance, projects `exitCode`/`exitedDate` through `ManagedContainer`, clears stale exit metadata when the init process starts again, and validates with focused resource tests plus `make test`.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Project exit metadata through container-compose discovery</td>
      <td>2026-06-22 01:00:00 BST</td>
      <td>2026-06-22 01:00:00 BST</td>
      <td>2026-06-22 01:06:26 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `ComposeContainerSummary` now carries `exitCode` and `exitedDate` from `ContainerSnapshot`, allowing Compose orchestration decisions to use the direct `apple/container` API instead of parsing CLI output or inventing plugin-side state.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Implement `service_completed_successfully` and stopped `wait` replay</td>
      <td>2026-06-22 01:00:00 BST</td>
      <td>2026-06-22 01:00:00 BST</td>
      <td>2026-06-22 01:06:26 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `up` and one-off `run` now wait for completed dependencies before starting dependents. A dependency passes when every target container either has stored `exitCode == 0` or returns `0` from the direct runtime wait API; non-zero dependency exits fail before the dependent starts. `container compose wait` now replays stored exit codes for already-stopped service containers on the fork-backed runtime. Upstream release support remains pending acceptance of #1562 or an equivalent exit-metadata API.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Add health status, healthcheck configuration, and health observation to the container fork</td>
      <td>2026-06-22 01:07:02 BST</td>
      <td>2026-06-22 01:07:02 BST</td>
      <td>2026-06-22 01:48:48 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: aligned the fork with [`apple/container#1502`](https://github.com/apple/container/issues/1502) and [`apple/container#1504`](https://github.com/apple/container/pull/1504), then added separate health configuration and observer handoffs so `ContainerSnapshot.health` is populated from a configured runtime probe. The CLI handoff `ISSUE-healthcheck-cli.md` / `PR-healthcheck-cli.md` adds Docker-style `container run/create --health-*` flags without moving Compose dependency logic into `apple/container`. This is fork-supported and upstream-pending, not released upstream support.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map explicit Compose healthchecks and `service_healthy` in container-compose</td>
      <td>2026-06-22 01:07:02 BST</td>
      <td>2026-06-22 01:07:02 BST</td>
      <td>2026-06-22 01:48:48 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now maps explicit service `healthcheck.test`, `interval`, `timeout`, `start_period`, `start_interval`, `retries`, `disable: true`, and `test: ["NONE"]` to the forked runtime creation flags. `depends_on.condition: service_healthy` waits for all dependency replicas to report `healthy`, continues polling while they are `starting`, fails on `unhealthy`, and rejects missing health status clearly. Dockerfile-inherited healthchecks are handled by the later image metadata slice below and remain fork-backed until that upstream image-config API is accepted.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Add restart policy create options to the container fork</td>
      <td>2026-06-22 01:48:48 BST</td>
      <td>2026-06-22 01:48:48 BST</td>
      <td>2026-06-22 02:08:32 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: implemented locally in the `stephenlclarke/container` `logs-integration-chris` branch as signed commit `fcbccbb` (`feat(api): add restart policy create options`). The slice references [`apple/container#286`](https://github.com/apple/container/issues/286) and [`apple/container#1258`](https://github.com/apple/container/pull/1258), adds `ContainerRestartPolicy`, `ContainerCreateOptions.restartPolicy`, Docker-style `container run/create --restart` parsing for `no`, `always`, `unless-stopped`, `on-failure`, and `on-failure:&lt;max-retries&gt;`, rejects `--rm` with non-default restart policy, and documents the PR shape in `ISSUE-restart-policy-create-options.md` / `PR-restart-policy-create-options.md` in the container fork.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Restart containers from runtime policy in the container fork</td>
      <td>2026-06-22 01:48:48 BST</td>
      <td>2026-06-22 02:08:32 BST</td>
      <td>2026-06-22 02:14:35 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: implemented locally in the `stephenlclarke/container` `logs-integration-chris` branch as signed commit `a20d6a3` (`feat(runtime): restart containers from policy`). The slice keeps the restart decision logic in a tested `ContainerRestartTracker`, applies exponential backoff with a stable-run reset window, suppresses `unless-stopped` after manual stops, honors `on-failure:&lt;max-retries&gt;`, and documents the PR shape in `ISSUE-restart-policy-runtime.md` / `PR-restart-policy-runtime.md`. Remaining upstream/runtime follow-ups are API-server startup auto-start, inspect restart count/status metadata, and update-time restart-policy changes.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map service-level Compose `restart` in container-compose</td>
      <td>2026-06-22 01:48:48 BST</td>
      <td>2026-06-22 02:14:35 BST</td>
      <td>2026-06-22 02:20:38 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now validates service `restart` values and maps service containers to `container run --restart &lt;policy&gt;` for `no`, `always`, `unless-stopped`, `on-failure`, and `on-failure:&lt;max-retries&gt;` when the fork-backed runtime is present. One-off `compose run` containers intentionally do not inherit service restart policy, matching Docker's one-off lifecycle expectations and avoiding `--rm` conflicts. Handoff files are `ISSUE-service-restart-policy.md` and `PR-service-restart-policy.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Add normalized `deploy.restart_policy` mapping</td>
      <td>2026-06-22 02:20:38 BST</td>
      <td>2026-06-22 02:36:27 BST</td>
      <td>2026-06-22 02:40:15 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now preserves `deploy.restart_policy` as structured normalizer output instead of reporting the whole field through `unsupportedDeployFields`. Swift orchestration gives deploy restart policy precedence over service-level `restart`, maps `condition: none` to `--restart no`, `condition: any` or an empty policy to `--restart always`, and maps `condition: on-failure` with optional `max_attempts` to `--restart on-failure[:max-retries]` against the fork-backed restart runtime. One-off `compose run` containers still do not inherit restart policies. At completion of this slice, Docker Compose `delay` and `window` were still documented apple/container runtime gaps; the follow-up timing slice below adds local fork support for those fields. Handoff files are `ISSUE-deploy-restart-policy.md` and `PR-deploy-restart-policy.md` in this repository; upstream context remains [`apple/container#286`](https://github.com/apple/container/issues/286) and [`apple/container#1258`](https://github.com/apple/container/pull/1258).</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Add restart timing support for `deploy.restart_policy.delay` and `window`</td>
      <td>2026-06-22 02:40:15 BST</td>
      <td>2026-06-22 02:45:37 BST</td>
      <td>2026-06-22 02:54:50 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: implemented locally as two signed PR-shaped commits. The `stephenlclarke/container` `logs-integration-chris` branch commit `7251c1b` (`feat(runtime): add restart policy timing`) adds optional `ContainerRestartPolicy.retryDelayInNanoseconds` and `successfulRunDurationInNanoseconds`, fixed-delay tracker behavior when configured, configured stable-run reset windows, parser coverage, hidden integration flags, and `ISSUE-restart-policy-timing.md` / `PR-restart-policy-timing.md`. The compose side now passes normalized `deploy.restart_policy.delay` and `window` to those timing flags for service containers. Released upstream support remains partial until equivalent restart timing primitives are accepted in [`apple/container`](https://github.com/apple/container).</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Expose Docker image `HEALTHCHECK` metadata in the container fork</td>
      <td>2026-06-22 03:02:43 BST</td>
      <td>2026-06-22 03:02:43 BST</td>
      <td>2026-06-22 03:12:12 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: implemented locally in the `stephenlclarke/container` `logs-integration-chris` branch as signed commit `831a013` (`feat(api): expose image healthcheck metadata`). The slice references [`apple/container#440`](https://github.com/apple/container/issues/440), [`apple/container#1502`](https://github.com/apple/container/issues/1502), and [`apple/container#1504`](https://github.com/apple/container/pull/1504), decodes Docker image config `Healthcheck` metadata from the existing image config content blob, projects it as `ImageResource.Variant.healthCheck`, and documents the PR shape in `ISSUE-image-healthcheck-metadata.md` / `PR-image-healthcheck-metadata.md` in the container fork.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map Dockerfile-inherited image healthchecks in container-compose</td>
      <td>2026-06-22 03:12:43 BST</td>
      <td>2026-06-22 03:12:43 BST</td>
      <td>2026-06-22 03:28:20 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now uses the direct image API to read fork-exposed Docker image healthcheck metadata. Services without an explicit Compose `healthcheck.test` can inherit Dockerfile `HEALTHCHECK` command, interval, timeout, start period, start interval, and retries; timing-only Compose overrides merge over image defaults. Explicit `disable: true` still maps to `--no-healthcheck`. Timing-only overrides reject before resources are created when the image does not expose a Dockerfile healthcheck command. Handoff files are `ISSUE-image-healthcheck-inheritance.md` and `PR-image-healthcheck-inheritance.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Materialize Docker Compose runtime config and secret file sources in container-compose</td>
      <td>2026-06-22 03:29:10 BST</td>
      <td>2026-06-22 03:29:10 BST</td>
      <td>2026-06-22 03:59:34 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now materializes Docker Compose top-level `configs.content`, `configs.environment`, and `secrets.environment` definitions into deterministic project-scoped local files under the per-user state root, then mounts them read-only through existing apple/container bind-mount primitives. Generated files use Compose default mode `0444` unless a later service grant mode overrides it; dry-runs render the target bind mounts without writing secret material; `down` removes the project-scoped materialized files after containers are removed. File-backed definitions continue to mount their source paths directly. External configs/secrets and strict service-level `uid`/`gid` ownership semantics remain separate apple/container/runtime boundary work. Handoff files are `ISSUE-config-secret-materialization.md` and `PR-config-secret-materialization.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Apply service-level modes to generated config and secret grants</td>
      <td>2026-06-22 04:16:00 BST</td>
      <td>2026-06-22 04:16:00 BST</td>
      <td>2026-06-22 04:16:00 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: generated runtime config/secret files now honor service grant `mode` values preserved by compose-go, parse octal strings such as `0440`, `0555`, and `0o400`, ignore writable bits per Compose semantics, and include the effective permission mode in the materialized file name so config-hash recreation detects mode-only changes. File-backed grants keep Docker Compose's bind-mount behavior and do not mutate source file metadata. `uid`/`gid` requests on generated grants still reject clearly because apple/container bind mounts do not expose config/secret ownership remapping. Handoff files are `ISSUE-config-secret-grant-mode.md` and `PR-config-secret-grant-mode.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Add explicit host entries to the container fork</td>
      <td>2026-06-22 04:33:28 BST</td>
      <td>2026-06-22 04:33:28 BST</td>
      <td>2026-06-22 04:33:28 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: implemented locally in the `stephenlclarke/container` `logs-integration-chris` branch by combining the resource-level direction from [`apple/container#1340`](https://github.com/apple/container/pull/1340) with the Docker-compatible `--add-host` CLI surface from [`apple/container#1563`](https://github.com/apple/container/pull/1563). The fork now has `ContainerConfiguration.HostEntry`, defaulted `hosts` decoding, repeatable `container run/create --add-host`, static IPv4/IPv6 validation, and runtime `/etc/hosts` injection before workload start. This remains fork-backed until one accepted upstream host-entry API lands. Handoff files are `ISSUE-host-entries.md` and `PR-host-entries.md` in the container fork.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map Compose `extra_hosts` to runtime host entries</td>
      <td>2026-06-22 04:33:28 BST</td>
      <td>2026-06-22 04:33:28 BST</td>
      <td>2026-06-22 04:33:28 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now accepts compose-go normalized static `extra_hosts` values, including `HOST=IP`, `HOST:IP`, and bracketed IPv6 source forms, validates IP literals before side effects, and maps service and one-off containers to `container run/create --add-host`. Docker's `host-gateway` magic value is handled by the separate host-gateway slice, Compose `domainname` is handled by the separate domain-name slice, and `links` / `external_links` remain separate host-identity gaps. Handoff files are `ISSUE-extra-hosts.md` and `PR-extra-hosts.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Resolve Docker `host-gateway` in the container fork</td>
      <td>2026-06-22 05:07:50 BST</td>
      <td>2026-06-22 05:07:50 BST</td>
      <td>2026-06-22 05:07:50 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: implemented locally in the `stephenlclarke/container` `logs-integration-chris` branch by accepting `host-gateway` as the address side of `--add-host`, storing it as a runtime-resolved host-entry marker, and resolving it to the first runtime network IPv4 gateway when generating `/etc/hosts`. Containers without an IPv4 gateway fail clearly. Handoff files are `ISSUE-host-gateway.md` and `PR-host-gateway.md` in the container fork.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map Compose `host-gateway` extra_hosts to runtime host entries</td>
      <td>2026-06-22 05:07:50 BST</td>
      <td>2026-06-22 05:07:50 BST</td>
      <td>2026-06-22 05:07:50 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now passes Compose `extra_hosts` values such as `host.docker.internal:host-gateway` through to fork-backed `container run/create --add-host`, leaving gateway address resolution to the runtime. Handoff files are `ISSUE-host-gateway.md` and `PR-host-gateway.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Add explicit container hostnames to the container fork</td>
      <td>2026-06-22 04:54:29 BST</td>
      <td>2026-06-22 04:54:29 BST</td>
      <td>2026-06-22 04:54:29 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: implemented locally in the `stephenlclarke/container` `logs-integration-chris` branch by adding `ContainerConfiguration.hostname`, shared `container run/create -h, --hostname` flags, RFC1123 hostname validation, and runtime resolution that prefers explicit hostnames while preserving existing network-derived defaults. This remains fork-backed until accepted upstream. Handoff files are `ISSUE-hostname.md` and `PR-hostname.md` in the container fork.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map Compose `hostname` to runtime hostnames</td>
      <td>2026-06-22 04:54:29 BST</td>
      <td>2026-06-22 04:54:29 BST</td>
      <td>2026-06-22 04:54:29 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now validates Compose service `hostname` with RFC1123 label rules and maps it to `container run/create --hostname` for service containers, `create`, and one-off `run` containers on the fork-backed integration branch. Compose `domainname` is handled by the separate domain-name runtime/plugin slice; `external_links` remains a separate networking identity gap. Handoff files are `ISSUE-service-hostname.md` and `PR-service-hostname.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Add explicit container domain names to the container fork</td>
      <td>2026-06-22 06:15 BST</td>
      <td>2026-06-22 06:15 BST</td>
      <td>2026-06-22 06:15 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: implemented locally in the `stephenlclarke/container` `logs-integration-chris` branch by adding `ContainerConfiguration.domainname`, shared `container run/create --domainname` flags, RFC1123 validation, and a runtime bridge through the existing `kernel.domainname` sysctl path. This remains fork-backed until accepted upstream, and the sysctl bridge can be replaced by a direct lower-runtime `domainname` mapping once `containerization` wires the OCI field into `vminitd`. Handoff files are `ISSUE-domainname.md` and `PR-domainname.md` in the container fork.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map Compose `domainname` to runtime domain names</td>
      <td>2026-06-22 06:15 BST</td>
      <td>2026-06-22 06:15 BST</td>
      <td>2026-06-22 06:15 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now validates Compose service `domainname` with RFC1123 label rules and maps it to `container run/create --domainname` for service containers, `create`, and one-off `run` containers on the fork-backed integration branch. Released upstream `apple/container` still needs accepted domain-name support before this can be enabled on branches pinned to upstream. Handoff files are `ISSUE-service-domainname.md` and `PR-service-domainname.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Add network attachment aliases to the container fork</td>
      <td>2026-06-22 05:31:11 BST</td>
      <td>2026-06-22 05:31:11 BST</td>
      <td>2026-06-22 05:31:11 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: implemented locally in the `stephenlclarke/container` `logs-integration-chris` branch by adding `AttachmentOptions.aliases`, repeatable `container run/create --network name,alias=...` parsing, XPC allocation payload support, allocator alias reservation/lookup/release behavior, and create-time collision checks. The slice intentionally keeps alias names unique because the current lookup API is hostname-like and not source-network-scoped; Docker-compatible shared aliases and DNSRR behavior remain future networking work. Handoff files are `ISSUE-network-aliases.md` and `PR-network-aliases.md` in the container fork.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map Compose service network aliases to runtime aliases</td>
      <td>2026-06-22 05:31:11 BST</td>
      <td>2026-06-22 05:31:11 BST</td>
      <td>2026-06-22 05:31:11 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now supports `services.*.networks.*.aliases` for the current single-network local subset by validating compose-go normalized aliases, de-duplicating them, and rendering `container run/create --network project_network,alias=name`. Aliases on unattached networks, invalid hostname values, and services with multiple networks are rejected before resources are created. Full Docker parity still needs multi-network attach/connect and source-network-aware DNS behavior in apple/container. Handoff files are `ISSUE-network-aliases.md` and `PR-network-aliases.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map legacy Compose `links` to dependency order and target aliases</td>
      <td>2026-06-22 05:52:10 BST</td>
      <td>2026-06-22 05:52:10 BST</td>
      <td>2026-06-22 05:52:10 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now supports the safe local `links` subset where source and target services share exactly one Compose network, including the compose-go normalized implicit `default` network. Link targets are included as implicit `service_started` dependencies, `SERVICE:ALIAS` entries project the alias onto the linked target service, and `SERVICE` entries project the target service name as the alias. Invalid aliases, missing targets, missing shared networks, multi-network links, and projected link aliases that collide with another active service alias are rejected before resources are created because current apple/container DNS lookup cannot model Docker's source-scoped or ambiguous shared-alias behavior yet. Handoff files are `ISSUE-links.md` and `PR-links.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Add default-network `links` regression coverage</td>
      <td>2026-06-22 06:27 BST</td>
      <td>2026-06-22 06:27 BST</td>
      <td>2026-06-22 06:27 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: compose-go normalizes undeclared service networks into a project-scoped `default` network, so the existing single-network link alias projection already covers Docker Compose's implicit default-network `links` behavior. Added regression coverage and corrected docs that previously described this as blocked. Handoff files are `ISSUE-links-default-network.md` and `PR-links-default-network.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map legacy Compose `external_links` to generated host entries</td>
      <td>2026-06-22 06:40 BST</td>
      <td>2026-06-22 06:40 BST</td>
      <td>2026-06-22 06:40 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now supports the safe local `external_links` subset where the source service has exactly one Compose network and the referenced existing apple/container container has exactly one attachment on the matching runtime network. `CONTAINER` and `CONTAINER:ALIAS` entries are resolved through the direct `ContainerClient.get` snapshot path, rendered as generated `--add-host ALIAS:IP` values, and folded into the transient service model so config-hash recreation detects external IP changes. Missing external containers, services without exactly one Compose network, and external containers without exactly one shared runtime attachment are rejected before resources are created. Full Docker parity still needs apple/container source-scoped DNS/link lookup and shared-alias semantics. Handoff files are `ISSUE-external-links.md` and `PR-external-links.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Support local Compose deploy job modes</td>
      <td>2026-06-22 06:58 BST</td>
      <td>2026-06-22 06:58 BST</td>
      <td>2026-06-22 06:58 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now preserves compose-go normalized `deploy.mode` values and supports Docker Compose local `replicated-job` / `global-job` behavior on the fork-backed integration branch. `up` starts each selected job replica detached, waits every job container through the direct lifecycle adapter, and fails before later services start if any job exits non-zero. Deploy job `restart_policy.condition: any` is rendered as `on-failure` because Docker jobs are never restarted after reaching the completed state. Service-level `restart: always` and `restart: unless-stopped` are rejected for job services before resources are created. Released upstream still needs accepted stopped-container exit metadata, such as [apple/container#1562](https://github.com/apple/container/pull/1562), before this can work against upstream `apple/container` without the fork. Handoff files are `ISSUE-deploy-job-modes.md` and `PR-deploy-job-modes.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map Compose `blkio_config` to the active apple/container `--blkio` contract</td>
      <td>2026-06-22 07:16 BST</td>
      <td>2026-06-22 07:16 BST</td>
      <td>2026-06-22 07:16 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now preserves compose-go normalized `blkio_config.weight`, `weight_device`, `device_read_bps`, `device_write_bps`, `device_read_iops`, and `device_write_iops`, validates weights/rates before runtime commands, and renders them as repeatable `container run/create --blkio` specs matching Chris George's [apple/container#1595](https://github.com/apple/container/pull/1595) CLI contract. This intentionally reuses #1595 rather than duplicating the runtime PR. The integration stack now pins to `stephenlclarke/containerization@integration/blkio-runtime`, which carries Chris George's [apple/containerization#739](https://github.com/apple/containerization/pull/739), so local end-to-end validation can proceed while released support still waits on upstream merges. Handoff files are `ISSUE-blkio-config.md` and `PR-blkio-config.md` in this repository.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Map Compose `sysctls` to the fork-backed apple/container `--sysctl` runtime bridge</td>
      <td>2026-06-22 07:52 BST</td>
      <td>2026-06-22 07:52 BST</td>
      <td>2026-06-22 07:52 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `container-compose` now validates compose-go normalized service `sysctls`, renders deterministic repeatable `container run/create --sysctl name=value` arguments, and rejects malformed sysctl names before issuing runtime commands. The matching apple/container fork slice exposes the already-present `ContainerConfiguration.sysctls` model through CLI create/run management flags so local Compose validation can proceed. Released upstream compatibility still waits on acceptance of the CLI bridge; full Docker parity for unsupported kernel namespaces remains runtime policy in apple/container rather than plugin behavior. Handoff files are `ISSUE-sysctls.md` and `PR-sysctls.md` in this repository, with `ISSUE-sysctl-cli.md` and `PR-sysctl-cli.md` in the container fork.</td>
    </tr>
  </tbody>
</table>

### Container Runtime Slab

<table>
  <thead>
    <tr>
      <th>Task</th>
      <th>Added</th>
      <th>Started</th>
      <th>Completed</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Finalize the assumed merged retrieval baseline</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td></td>
    </tr>
    <tr>
      <td colspan="4">Notes: rebase the local `logs-integration-chris` branch after #1592/#1764/#1765 land, drop duplicate parser/filter code, keep `ContainerLogOptions` as retrieval-only state, keep replay policy outside presentation flags, and preserve tests for negative tail, `--tail 0 --follow`, EOF final records, split records, legacy raw records, and line-based filtering.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Upstream structured log record storage</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td>2026-06-21 20:50:49 BST</td>
      <td>2026-06-21 20:50:49 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: split from the local `logs-integration-chris` branch into a small apple/container branch named `logs-structured-record-storage`. The branch writes raw workload bytes to `stdio.log` and Docker-like line-framed JSON Lines sidecar records to `stdio.jsonl`. Each sidecar record contains `timestamp`, `stream`, and base64 `data`; final complete EOF records and oversized unterminated 16 KiB chunks are covered by tests. Keep this runtime-only; no Compose prefixes, colors, service names, or replica policy. Upstream support remains partial until this branch is turned into an apple/container PR and accepted.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Upstream structured retrieval APIs</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td>2026-06-21 21:11:04 BST</td>
      <td>2026-06-21 21:11:04 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: split from the local `logs-integration-chris` branch into a small apple/container branch named `logs-structured-record-api`. The branch stacks on `logs-structured-record-storage` and exposes `ContainerClient.logRecords(id:options:)` for decoded `ContainerLogRecord` snapshots plus `ContainerClient.logRecordFile(id:)` for the active `stdio.jsonl` file handle. The wire surfaces are XPC routes `containerLogRecords` and `containerLogRecordFile`; retrieval options are `ContainerLogOptions.tail`, `ContainerLogOptions.since`, and `ContainerLogOptions.until`. Timestamp rendering stays a command/plugin presentation concern. Upstream support remains partial until this branch is turned into an apple/container PR and accepted; rotated replay and legacy raw-log fallback remain separate slices.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Upstream static rotated replay and bounded tail scan</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td>2026-06-21 22:10:01 BST</td>
      <td>2026-06-21 22:32:35 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: implemented locally in the `stephenlclarke/container` `logs-integration-chris` branch as commit `86a9bda` with handoff files `ISSUE-logs-static-rotated-tail.md` and `PR-logs-static-rotated-tail.md`. The runtime-owned behavior is `ContainerLogReplayOptions(includeRotated:)` or an accepted replay-policy equivalent, deterministic active-plus-rotated retention ordering, negative tail as all, `tail 0` as empty, line reconstruction across file boundaries, and bounded reverse scanning for static raw replay. This avoids making `container logs -n 10` replay full retained history. Keep Compose-specific prefixes, colors, service names, and replica ordering out of the runtime branch. Split this into an Apple-facing PR branch after #1592/#1764/#1765 settle.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Upstream raw rotation-aware follow stream</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td>2026-06-21 23:43:58 BST</td>
      <td>2026-06-21 23:43:58 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: implemented locally in the `stephenlclarke/container` `logs-integration-chris` branch and documented with `ISSUE-logs-rotation-aware-follow.md` and `PR-logs-rotation-aware-follow.md`. The runtime-owned raw follow behavior is `ContainerClient.followLogs(id:options:)`, XPC route `containerFollowLogs`, Docker-style initial replay for negative, zero, and positive tail values, rename-based active-file detection, final reads from the renamed active file, and reopening the recreated active path without polling merged snapshots. Keep Compose service fan-out, prefixes, colors, and replica ordering out of the runtime branch.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Upstream structured rotation-aware follow stream</td>
      <td>2026-06-21 23:43:58 BST</td>
      <td>2026-06-22 00:12:53 BST</td>
      <td>2026-06-22 00:36:46 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: implemented locally in the `stephenlclarke/container` `logs-integration-chris` branch as commit `43add25` and documented with `ISSUE-logs-structured-rotation-aware-follow.md` and `PR-logs-structured-rotation-aware-follow.md`. The runtime-owned structured follow behavior is `ContainerClient.followLogRecords(id:options:)`, XPC route `containerFollowLogRecords`, retained `stdio.jsonl` replay, rename-based active-file detection, logical-line reconstruction before `tail`/`since`/`until`, `tail 0` open-fragment skipping, and final partial-line flushing when the runtime stream ends. Keep Compose service fan-out, prefixes, colors, and replica ordering out of the runtime branch.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Upstream local logging policy model</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td>2026-06-21 22:38:05 BST</td>
      <td>2026-06-21 22:38:05 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: the first upstream-sized slice is the typed `ContainerLogConfiguration` model plus `ContainerConfiguration.logging` default decoding. The local code-bearing commit is `e41e630`; handoff files are `ISSUE-logs-local-policy-model.md` and `PR-logs-local-policy-model.md` in the container fork. This slice is model-only and deliberately excludes CLI flags, disabled capture, writer rotation, and Compose policy.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Upstream disabled local log capture</td>
      <td>2026-06-21 22:38:05 BST</td>
      <td>2026-06-21 22:44:22 BST</td>
      <td>2026-06-21 22:44:22 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: split from local commit `6cbf778` and documented with `ISSUE-logs-disabled-local-capture.md` and `PR-logs-disabled-local-capture.md` in the container fork. This slice adds the `.none` local storage policy behavior and runtime writer suppression while preserving attached stdio. It deliberately excludes CLI flags, Compose mapping, remote logging drivers, and writer rotation. Upstream support remains partial until this branch is turned into an apple/container PR and accepted.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Upstream log driver and local option parsing</td>
      <td>2026-06-21 22:38:05 BST</td>
      <td>2026-06-21 22:51:12 BST</td>
      <td>2026-06-21 22:51:12 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: split from local commits `f787d3d`, `9cca5b3`, and `ee28563` and documented with `ISSUE-logs-local-driver-options.md` and `PR-logs-local-driver-options.md` in the container fork. This maps `json-file` and `local` to local capture, maps `none` to disabled capture, parses local `max-size` and `max-file`, rejects unsupported drivers/options precisely, and keeps remote logging drivers, metadata options, compression, and Compose presentation policy out of scope. Upstream support remains partial until this branch is turned into an apple/container PR and accepted.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Upstream writer-level local log rotation</td>
      <td>2026-06-21 22:38:05 BST</td>
      <td>2026-06-21 23:00:38 BST</td>
      <td>2026-06-21 23:00:38 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: split from local commit `06862b7` and documented with `ISSUE-logs-local-writer-rotation.md` and `PR-logs-local-writer-rotation.md` in the container fork. This keeps rotation in the runtime writer, preserves raw `stdio.log` and structured `stdio.jsonl` files together, applies `max-size` and `max-file` from `ContainerLogConfiguration`, handles active-file-only retention, seeds size counters from existing active files, and pairs with static rotated replay rather than Compose-specific follow polling. Upstream support remains partial until this branch is turned into an apple/container PR and accepted.</td>
    </tr>
  </tbody>
</table>

### container-compose Work Unlocked By The Runtime Slab

<table>
  <thead>
    <tr>
      <th>Task</th>
      <th>Added</th>
      <th>Started</th>
      <th>Completed</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Retarget static raw replay to runtime-owned rotated tail</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td>2026-06-21 22:10:01 BST</td>
      <td>2026-06-21 22:32:35 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: `ContainerClientLogManager` asks the direct API for `ContainerLogOptions(tail:)` and `ContainerLogReplayOptions(includeRotated: true)` on static raw logs. The runtime honors that request with bounded static rotated replay, and the plugin stays a thin fan-out and formatting layer.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Switch timestamped logs to the upstream structured API</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td>2026-06-22 00:05:48 BST</td>
      <td>2026-06-22 00:36:46 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: static timestamped/time-window logs use `ContainerClient.logRecords(id:options:replay:)`; followed timestamped/time-window logs now use `ContainerClient.followLogRecords(id:options:)`. The plugin renders returned structured records and keeps Compose fan-out, prefixes, color, and formatting local. Released support still waits for the upstream structured storage/API/follow PRs to be accepted.</td>
    </tr>
    <tr>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Replace raw rotated-follow polling with runtime follow stream</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td>2026-06-22 00:05:48 BST</td>
      <td>2026-06-22 00:05:48 BST</td>
    </tr>
    <tr>
      <td colspan="4">Notes: removed the plugin-side repeated merged-snapshot polling path by calling `ContainerClient.followLogs(id:options:)` on the fork integration stack. Compose fan-out concurrency, line reconstruction, container-stop flushing, and per-service prefixing remain in this repository, while the runtime owns raw rotation/truncation boundaries. Released support still waits for the upstream raw-follow API to be accepted.</td>
    </tr>
    <tr>
      <td><img alt="OUTSTANDING" src="https://img.shields.io/badge/OUTSTANDING-6B7280?style=flat-square"> Promote local logging driver mappings to released support</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td></td>
      <td></td>
    </tr>
    <tr>
      <td colspan="4">Notes: after apple/container logging policy lands, enable released support for Compose `logging.driver: json-file`, `logging.driver: local`, `logging.driver: none`, `logging.options.max-size`, and `logging.options.max-file`; keep remote logging drivers and remote-only options rejected with precise apple/container runtime-gap messages.</td>
    </tr>
    <tr>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Add Docker Compose comparison fixtures for the completed log surface</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td>2026-06-21 22:10:01 BST</td>
      <td></td>
    </tr>
    <tr>
      <td colspan="4">Notes: 2026-06-21 23:18:03 BST added `Tests/ComposeCoreTests/Fixtures/logging/docker-compose-rotated-tail.expected`, `scripts/capture-docker-compose-log-fixtures.sh`, and the optional `make docker-log-fixtures` / `make docker-log-fixtures-update` targets. The captured Docker Engine 29.2.1 / Docker Compose 5.1.4 fixture records rotated `json-file` and `local` behavior for `logs --tail 5`, `logs --tail 0`, `logs --tail -1`, and `logs --tail all`; retained full-history line counts differ by driver, but positive tail remains per-service logical-line based. Keep live Docker comparisons optional in CI because they require Docker Engine. Remaining fixture coverage should add RFC 3339/RFC 3339 nano, Unix timestamps, relative durations, `--tail 0 --follow`, blank records, CRLF/CR separators, final partial lines, and selected-service multi-replica follow over time.</td>
    </tr>
    <tr>
      <td><img alt="OUTSTANDING" src="https://img.shields.io/badge/OUTSTANDING-6B7280?style=flat-square"> Update branch compatibility after runtime releases</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td></td>
      <td></td>
    </tr>
    <tr>
      <td colspan="4">Notes: once each apple/container PR lands, update `COMPATIBILITY.md` on `apple-container-compatible`, `full-compose-preview`, and `logs-integration` so released upstream support, fork-only support, and remaining runtime gaps stay distinct.</td>
    </tr>
  </tbody>
</table>

## Related Compose Implementations

The work in this repository overlaps with two public Compose efforts called out in [`apple/container#1752`](https://github.com/apple/container/issues/1752#issuecomment-2999970912). The intent here is to track overlap and avoid duplicated upstream effort while keeping this repo focused on a standalone `container compose` plugin shape.

### full-chaos/container-compose

Repository: [`full-chaos/container-compose`](https://github.com/full-chaos/container-compose)

Container fork used: [`full-chaos/container`](https://github.com/full-chaos/container), pinned from `Package.swift` to branch [`tier2-fork-patches`](https://github.com/full-chaos/container/tree/tier2-fork-patches). Its README also describes an opt-in [`dev`](https://github.com/full-chaos/container/tree/dev) branch for fork-forward runtime features.

Overlap: <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square">

- Implements a broad Docker Compose-like CLI and runtime abstraction layer for Apple containers.
- Tracks fork-forward runtime gaps that also matter to this repo, including log options, events, restart policy, healthcheck observation, richer IPAM, process flag factoring, and resource controls.
- [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11) overlaps directly with this log plan by adding `ContainerLogOptions` for `since` and `timestamps` to `ContainerClient.logs`.
- Chris George confirmed the [`apple/container#1752`](https://github.com/apple/container/issues/1752#issuecomment-4752812508) direction on `2026-06-19`. The local `logs-integration-chris` branch preserves his API shape first, then layers the broader Compose log capabilities as separate signed commits that can be split into upstream PRs.

How this repo complements it: <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square">

- This repo keeps Compose normalization behind `compose-go` so Docker Compose v2 merge, interpolation, profile, include, and extension semantics stay aligned with Docker's maintained implementation.
- This repo is shaped as a `container compose` plugin using the current plugin install layout, with direct `apple/container` APIs used wherever available.
- The local log work goes beyond raw line filtering by adding structured timestamped records and a `ContainerClient.logRecords` API. It is now based on `full-chaos/container#11` so upstream PRs can reuse compatible naming and wire semantics rather than creating a competing API shape.

### Mcrich23/Container-Compose

Repository: [`Mcrich23/Container-Compose`](https://github.com/Mcrich23/Container-Compose)

Container fork used: the public `Container-Compose` package currently depends on [`apple/container`](https://github.com/apple/container) from `1.0.0`. The related fork [`Mcrich23/container`](https://github.com/Mcrich23/container) contains an [`add-compose`](https://github.com/Mcrich23/container/tree/add-compose) branch with the earlier in-tree plugin work and an [`add-command-option-group-function-macro`](https://github.com/Mcrich23/container/tree/add-command-option-group-function-macro) branch related to plugin OptionGroup passthrough.

Overlap: <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square">

- Provides the original Swift Compose implementation lineage that later fed discussion around plugin support and OptionGroup passthrough.
- Uses `ContainerCommands` heavily, which overlaps with the plugin ergonomics discussion in [`apple/container#1410`](https://github.com/apple/container/discussions/1410), [`apple/container#633`](https://github.com/apple/container/issues/633), and [`apple/container#717`](https://github.com/apple/container/pull/717).
- Covers basic Compose model structures, command wiring, service dependencies, volumes, networks, and logging surfaces.

How this repo complements it: <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square">

- This repo deliberately does not depend on unsettled OptionGroup passthrough for core orchestration. It uses direct `ContainerClient`, `NetworkClient`, `ClientVolume`, image, stats, copy, exec, and lifecycle APIs where possible.
- This repo treats earlier Compose branches as reference material, but keeps the implementation standalone and split into upstreamable runtime/API slices plus plugin-side Compose behavior.
- The log work here can provide the lower-level API surface that command-oriented Compose plugins need, without requiring them to parse CLI output or replay whole log files.

## Compatibility Snapshot

<table>
  <thead>
    <tr>
      <th>Area</th>
      <th>Status</th>
      <th>Meaning</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>Raw stdio log replay</td>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"></td>
      <td>Existing Compose-managed containers can have their stdio log file read through the direct apple/container API.</td>
    </tr>
    <tr>
      <td>Basic follow and tail</td>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"></td>
      <td><code>--follow</code>, <code>--tail N</code>, <code>-n N</code>, and <code>--tail all</code> are wired for resolved runtime containers.</td>
    </tr>
    <tr>
      <td>Replica and service aggregation</td>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"></td>
      <td><code>logs</code> now includes all selected service replicas by default. Explicit <code>--index</code> narrows to one replica.</td>
    </tr>
    <tr>
      <td>Multi-service follow</td>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"></td>
      <td>Docker Compose follows all selected services together. container-compose now starts all selected service and replica streams concurrently.</td>
    </tr>
    <tr>
      <td>Compose log presentation</td>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"></td>
      <td>Default output prefixes each line with service/index identity, ANSI color is applied when terminal policy allows it, and <code>--no-log-prefix</code> emits raw output.</td>
    </tr>
    <tr>
      <td>Timestamp and time-window filtering</td>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"></td>
      <td><img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> Static and followed <code>--timestamps</code>, <code>--since</code>, and <code>--until</code> are implemented on the local integration stack through structured records. Static rendering delegates line-correct tail and time filters to the direct apple/container record API, then renders the returned records. Followed structured logs delegate replay, rotation, tail, and time filters to the runtime structured follow stream. Upstream acceptance still needs the structured storage, retrieval, and follow PRs.</td>
    </tr>
    <tr>
      <td>Service logging drivers/options</td>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"></td>
      <td><img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> File-backed <code>json-file</code> and <code>local</code> logging map to apple/container local stdio capture. <code>none</code> maps to disabled persisted capture on the local integration stack. Local <code>max-size</code>/<code>max-file</code> options now map to apple/container <code>--log-opt</code> flags; static rotated local replay, raw rotation-aware follow, and structured rotation-aware follow work on the local container stack. Remote drivers and upstream acceptance remain open.</td>
    </tr>
    <tr>
      <td>Exact byte/line fidelity</td>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"></td>
      <td><img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> container-compose preserves blank line records, raw and structured followed partial lines, and non-UTF-8 payload bytes on the local integration stack. stdout/stderr identity remains available in structured records but is not yet user-visible Compose formatting.</td>
    </tr>
  </tbody>
</table>

## Detailed Work Items

### L1. Raw Stdio Log Replay

Status: <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">

Docker Compose surface: `docker compose logs SERVICE`, `docker compose logs` for existing service containers.

Current `container-compose` behavior:

- Resolves a Compose service container to the deterministic apple/container runtime ID.
- Calls `ContainerClient.logs(id:options:replay:)` through `ContainerClientLogManager`.
- Reads the stdio file handle and emits existing log bytes.
- Supports stopped-container replay when the apple/container bundle and log files still exist.

Current [`apple/container`](https://github.com/apple/container) behavior:

- `container logs <container-id>` reads the same stdio log file handle.
- `ContainerClient.logs(id:)` returns stdio and boot log handles.

Remaining work:

- None for the basic one-container raw replay path.

### L2. Follow Mode

Status: <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">

Peer touchpoint: <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square">

Peer touchpoint details:

- <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> Runtime log-follow behavior overlaps with the fork-forward log work in [`full-chaos/container-compose`](https://github.com/full-chaos/container-compose) and should be compared before proposing apple/container follow APIs.
- <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> This repo's plugin-side fan-out, service/replica aggregation, and rotated snapshot cursor tests can validate candidate lower-level log-follow primitives used by command-oriented Compose implementations, but they should not be mistaken for an accepted apple/container cursor API.

Docker Compose surface: `docker compose logs --follow [SERVICE...]`.

Current `container-compose` behavior:

- Supports `--follow` for resolved service container targets.
- Starts multiple selected service and replica streams concurrently with a throwing task group.
- Surfaces stream failures instead of letting one followed stream starve later targets.
- Uses a plugin-side polling path over merged raw log replay snapshots, emits only appended complete log records, and flushes an unterminated final record when direct runtime status shows the target is no longer live.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Upstream `container logs --follow <container-id>` follows one container log file.
- The local `logs-integration-chris` branch follows active raw log handles for the CLI and exposes static rotated replay through `ContainerClient.logs(id:options:replay:)` with `ContainerLogReplayOptions(includeRotated: true)`.
- The direct API exposes container status through `ContainerClient.get`, which lets clients distinguish live buffering from stopped final-line flushing.

Remaining work:

- None known for plugin-side follow fan-out and line splitting. Timestamped or structured follow filtering is tracked in the timestamp section because it depends on the local apple/container structured record APIs being upstreamed.

Completed implementation:

- `ComposeOrchestrator.logs` resolves the full target set first, then fans out multiple `ContainerLogManaging.logs` streams with a task group.
- Regression coverage proves a scaled service starts both followed replicas before either stream is released.
- `ContainerClientLogManager` preserves blank followed records and flushes a final partial line when the stream closes.

### L3. Tail Mode

Status: <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">

Docker Compose surface: `docker compose logs --tail N`, `docker compose logs -n N`, and `docker compose logs --tail all`.

Current `container-compose` behavior:

- Accepts `--tail`, `-n`, compact `-n5`, and `all`.
- Validates that numeric tail values are non-negative.
- Implements tailing locally against the apple/container stdio log file.

Current [`apple/container`](https://github.com/apple/container) behavior:

- `container logs -n <n>` implements the same basic one-container tail path.
- The direct API exposes the file handle needed for plugin-side tailing.

Remaining work:

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Deterministic Compose line-boundary fixtures now cover empty logs, blank records, final newlines, CRLF/CR separators, and unterminated final records. Live Docker Compose capture can be added when `docker compose` and a running daemon are available locally.

### L4. Service and Replica Selection

Status: <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">

Docker Compose surface: `docker compose logs [SERVICE...]` and `docker compose logs --index N SERVICE`.

Current `container-compose` behavior:

- Supports service name filtering.
- Includes every existing Compose-managed replica for selected services when `--index` is omitted.
- Includes every existing Compose-managed service container in the project when no service is selected.
- Supports `--index N` to narrow each selected service to one replica.
- Falls back to deterministic configured replica names during dry-run.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Supports direct lookup by container ID through existing list/get APIs and direct log handles by ID.
- Does not need a special multi-replica primitive for plugin-side enumeration because Compose labels and deterministic names already identify service replicas.

Remaining work:

- None for service and replica target resolution.

### L5. Prefixes, Colors, and `--no-log-prefix`

Status: <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">

Docker Compose surface: default prefixed output, `--no-log-prefix`, and `--no-color`.

Current `container-compose` behavior:

- Prefixes default log output as <code>service-index | line</code>.
- Prefixes each line of a multiline emitted log chunk.
- Supports `--no-log-prefix` to emit raw log output.
- Applies deterministic ANSI color to log prefixes when stdout is interactive or `--ansi always` is set.
- Disables ANSI color with `--no-color` or `--ansi never`.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Exposes raw container stdio logs.
- Does not attach Compose service names, replica indexes, or color metadata to log records.

Missing behavior:

- None currently known for prefix/color presentation.

Completed implementation:

- `ComposeOrchestrator.logs` wraps the per-target emitter with a service/index prefix policy before handing it to `ContainerLogManaging`.
- `--no-log-prefix` bypasses that wrapper and preserves raw log output.
- CLI log color policy honors `--no-color`, `--ansi never`, `--ansi always`, and stdout terminal detection before enabling ANSI prefix colors.
- Tests cover prefixed output, multiline prefixing, colored prefixes, raw output, and scaled replica prefixes.

Remaining plugin work:

- None.

### L6. Timestamps, `--since`, and `--until`

Status: <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">

Peer touchpoint: <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square">

Peer touchpoint details:

- <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11) works in the same runtime log-options space and should be compared before opening apple/container PRs.
- <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> This repo's structured record path can provide timestamp, stream, and byte-preserving data that command-oriented Compose implementations can consume.

Docker Compose surface: `docker compose logs --timestamps`, `docker compose logs --since VALUE`, and `docker compose logs --until VALUE`.

Current `container-compose` behavior:

- Exposes `--since` and `--until` on `compose logs`.
- Accepts RFC 3339 timestamps, Unix timestamps in seconds with optional fractional seconds, and relative durations such as `30m`, `2h`, or `1h30m`.
- Parses static timestamp filters and passes them to the direct structured record API.
- Uses structured `ContainerClient.logRecords(id:options:replay:)` on the local integration stack to render static `logs --timestamps` without parsing timestamps from application output.
- Uses `ContainerClient.logRecords(id:options:replay:)` with direct API `tail`, `since`, and `until` options on the local integration stack for static `--timestamps`, `--since`, and `--until`, then renders the returned line-correct records.
- Uses `ContainerClient.followLogRecords(id:options:)` on the local integration stack for followed structured logs, so the runtime owns retained replay, rotation, `tail`, `since`, `until`, open-fragment handling, and stream termination.
- Stops structured follow when the runtime structured stream reaches the `--until` deadline, even when no new log records arrive.
- Buffers split structured records while the followed runtime stream is open, then flushes the final unterminated structured record when the runtime stream ends.
- Cannot reconstruct capture timestamps for logs produced before the structured record store exists.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Upstream exposes raw stdio and boot log file handles.
- The local `logs-integration-chris` branch exposes static `tail`, `since`, and `until` filtering through `ContainerClient.logs(id:options:replay:)`, with raw `tail` filtering performed without requiring UTF-8 decoding.
- The local `logs-integration-chris` branch accepts RFC 3339, RFC 3339 nano, Unix timestamps in seconds with optional fractional seconds, and relative durations for `container logs --since` and `--until`.
- The local `logs-integration-chris` branch stores timestamped runtime records at Docker-like line boundaries, flushes final complete records at static EOF, and exposes `ContainerClient.logRecords(id:options:replay:)` with timestamp, stream, raw bytes, and line-correct tail/since/until filtering for static replay.
- The local `logs-integration-chris` branch exposes `ContainerClient.logRecordFile(id:)` for clients that want direct structured JSONL file access.
- The local `logs-integration-chris` branch renders static `container logs --timestamps` output through structured records before rendering; upstream review still needs to confirm the contract across legacy raw logs, rotated retention, and truncation behavior.
- The local `logs-integration-chris` branch exposes `ContainerClient.followLogRecords(id:options:)` and renders followed `container logs --timestamps`, `--since`, and `--until` output from a runtime-owned structured record stream; it renders plain unfiltered `container logs --follow` through a raw rotation-aware follow stream.
- Does not yet have upstream-reviewed cursor, truncation, rotation, or retention semantics for long-lived structured/timestamped rotation-aware follow clients.
- Still needs upstream review to confirm `tail`, `since`, and `until` filtering is applied to reconstructed logical log lines rather than raw storage fragments in every record source.

Missing behavior:

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Static and followed `--timestamps`, `--since`, and `--until` work on the local integration stack, but still need upstream apple/container PR acceptance before they can be treated as released support.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Line-correct structured replay filtering works locally, but Docker parity still depends on upstream apple/container acceptance and explicit coverage for legacy raw logs, rotated retention, and truncation behavior.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> A stable record format plus runtime structured follow behavior now exist locally; upstream review needs to confirm cursor, retention, and truncation behavior before plugin releases can depend on it.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Capture timestamps are unavailable for containers that only have legacy raw stdio logs.

Implementation direction:

- Split the local [`apple/container`](https://github.com/apple/container) log work into small upstream PRs from `logs-integration-chris`: retrieval-only log options, replay policy options, line-correct filtered static replay, Docker-compatible timestamp parsing, structured timestamped record storage, structured record retrieval, static rotated replay, local logging policy and rotation, raw rotation-aware follow, and a later structured rotation-aware follow design.
- Keep the upstreamable API shape aligned with [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11) so both Compose implementations can converge on one runtime contract.
- Add golden behavior tests using RFC 3339 timestamps, Unix timestamps, relative durations, followed timestamp output, and combined `--since`/`--until` windows after the upstream API shape settles.

Completed implementation:

- Completed `2026-06-19 21:55:01 BST`: static `container-compose` timestamped logs now pass `tail`, `since`, and `until` to the direct `ContainerClient.logRecords(id:options:replay:)` API instead of reimplementing those filters locally.
- Completed `2026-06-19 21:55:01 BST`: the local apple/container branch now treats structured records as Docker-like line-framed log entries, flushes a final complete JSON record at static EOF/deadline EOF, and keeps live follow from treating a writer's incomplete JSON bytes as a record.
- Completed `2026-06-19 22:49:12 BST`: the local apple/container branch split retrieval filters from replay policy, added shared Docker-compatible timestamp parsing, and applies structured `tail`, `since`, and `until` filters after logical log-line reconstruction.
- Completed `2026-06-19 22:49:12 BST`: `container-compose` structured follow first moved to the active `ContainerClient.logRecordFile(id:)` JSONL file with a bounded cursor instead of repeatedly polling full merged structured snapshots.
- Completed `2026-06-21 20:50:49 BST`: the upstreamable `logs-structured-record-storage` branch now documents and tests the active `stdio.log` raw byte format and `stdio.jsonl` JSON Lines structured record format with `timestamp`, `stream`, and base64 `data`.
- Completed `2026-06-21 21:11:04 BST`: the upstreamable `logs-structured-record-api` branch now documents and tests the active structured retrieval surfaces: `ContainerClient.logRecords(id:options:)`, `ContainerClient.logRecordFile(id:)`, `ContainerLogRecord`, XPC routes `containerLogRecords` and `containerLogRecordFile`, and `ContainerLogOptions.tail/since/until` retrieval filters.
- Completed `2026-06-21 21:16:15 BST`: PR and issue-ready design choices for the structured log slices are recorded in the container fork's [Structured Log Records PR Notes](https://github.com/stephenlclarke/container/blob/logs-structured-record-api/docs/structured-log-records-pr-notes.md), including raw versus structured storage, record boundaries, retrieval-filter ownership, XPC surfaces, Compose boundaries, and out-of-scope follow-up PRs.
- Completed `2026-06-22 00:36:46 BST`: `container-compose` structured follow now calls `ContainerClient.followLogRecords(id:options:)` instead of reading the active record file directly; the runtime owns retained replay, rotation, `tail`, `since`, `until`, and stream termination while the plugin owns Compose formatting and service fan-out.

### L7. Service Logging Driver and Options

Status: <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">

Peer touchpoint: <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square">

Peer touchpoint details:

- <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> Other Compose implementations also hit apple/container's missing logging-policy layer, so any design should be coordinated before mapping remote drivers or driver options.
- <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> This repo's current local-driver acceptance and precise rejection boundary can be reused by command-oriented Compose implementations while the apple/container policy API is still unsettled.

Docker Compose surface: service `logging.driver`, `logging.options`, legacy `log_driver`, and legacy `log_opt`.

Current `container-compose` behavior:

- Accepts `logging.driver: json-file`, `logging.driver: local`, `logging.options: {}`, and legacy `log_driver: json-file` or `log_driver: local` as mappings to apple/container's local stdio log capture.
- Maps `logging.driver: none` and legacy `log_driver: none` without options to apple/container's local disabled-capture policy on the local integration stack.
- Maps local `logging.options` and legacy `log_opt` keys `max-size` and `max-file` to apple/container `--log-opt` flags for the default, `json-file`, and `local` drivers.
- Rejects remote or otherwise unsupported service logging drivers, unsupported logging options, and any logging options attached to `none` before creating resources.
- Preserves the compatibility boundary in tests and `COMPATIBILITY.md`.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Captures container stdio to local runtime files.
- The local `logs-integration-chris` branch adds a typed local logging policy, treats `container create/run --log-driver json-file` and `--log-driver local` as local stdio capture aliases, supports disabled persisted capture through `--log-driver none`, parses `container create/run --log-opt max-size=<size>` and `--log-opt max-file=<count>` into the local rotation policy, honors configured local `maxSizeInBytes` / `maxFileCount` at the runtime writer, and exposes static rotated raw and structured replay through direct log options.
- Does not expose Docker-compatible remote logging driver selection or remote logging backends.

Missing behavior:

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Disabled persisted capture works on the local integration stack but still depends on upstream apple/container PR acceptance before it can be treated as released support.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Writer-level local rotation, CLI option parsing, Compose option mapping, static rotated replay, raw rotation-aware follow, and structured/timestamped rotation-aware follow work on the local integration stack for `max-size` and `max-file`, but the follow-stream contracts still need upstream apple/container review and acceptance.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Remote or non-local runtime logging driver selection per container.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Driver-specific options such as syslog endpoint, labels, env inclusion, and non-local option handoff.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Clear policy for unsupported Docker logging drivers on macOS.

Implementation direction:

- Split the local [`apple/container`](https://github.com/apple/container) logging policy work into small upstream PRs: policy model, disabled local capture, and CLI/direct API bridge.
- Keep `container-compose` rejection behavior for remote drivers, options on `none`, and non-local logging options until apple/container exposes compatible runtime primitives.
- Keep local-driver rotation support behind the merged replay cursor until upstream review settles cursor, truncation, and retention semantics for followed logs.

### L8. Exact Log Fidelity

Status: <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">

Peer touchpoint: <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square">

Peer touchpoint details:

- <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> Byte-preserving and line-boundary fixtures are plugin-side guardrails that can validate whichever runtime log API shape becomes shared upstream.

Docker Compose surface: raw application stdout/stderr content displayed through `docker compose logs`.

Current `container-compose` behavior:

- Preserves blank line records in full replay, local tailing, and followed streams.
- Buffers followed output so split raw and structured lines are not emitted until complete, uses the direct runtime status API to detect when a followed container is no longer live, and flushes the final partial line at that stop boundary.
- Emits log byte records through a dedicated data emitter so non-UTF-8 payloads are preserved in raw, prefixed, followed, and timestamped output.
- Covers Compose line-boundary fixtures for empty logs, blank records, final newlines, CRLF/CR separators, prefixed blank records, and unterminated final records.
- The local structured record path preserves stdout/stderr identity in apple/container records, but Compose output formatting does not currently distinguish streams.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Upstream stores a merged stdio file and returns a file handle.
- The local `logs-integration-chris` branch also stores structured records with stdout/stderr stream metadata and per-record capture timestamps. Records are emitted at line boundaries, final unterminated data is flushed when a stream closes, and oversized unterminated data is chunked at a Docker-like 16 KiB boundary.

Missing behavior:

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Decide whether stdout/stderr stream identity should influence future Compose formatting or filtering.

Implementation direction:

- Add live Docker Compose output capture for the line-boundary fixtures when `docker compose` and a running daemon are available locally.
- Keep the plugin-side blank-line and split-line regression tests as guardrails.
- Keep the stream-identity data available through structured records while avoiding plugin formatting changes unless Docker Compose comparison fixtures require them.

## Suggested Work Order

1. <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Implement all-replica target resolution for `logs`.
2. <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Implement concurrent multi-service and multi-replica follow.
3. <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Add default Compose prefixes, `--no-log-prefix` behavior, and color policy.
4. <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Fix blank-line and line-boundary fidelity that can be solved from current raw file handles.
5. <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> Upstream the local apple/container timestamped structured log records, direct retrieval API, static rotated replay, raw rotation-aware follow stream, and structured rotation-aware follow stream.
6. <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> Propose apple/container service logging policy primitives for remote drivers and remaining non-local logging options.
7. <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> Revisit service `logging` mappings beyond local file-backed drivers after upstream runtime APIs exist.

## Acceptance Criteria

- `container compose logs` with no services prints logs for every Compose-managed service container in the project.
- `container compose logs SERVICE` prints logs for every replica of that service unless `--index` narrows the target.
- `container compose logs --follow` streams all selected containers concurrently and surfaces stream failures.
- Default output includes Compose-style service/replica prefixes and optional color; `--no-log-prefix` and `--no-color` alter real behavior.
- `--tail` applies independently to each selected container.
- Blank lines and trailing newline behavior match Docker Compose v2 fixtures.
- Static and followed `--timestamps`, `--since`, and `--until` match Docker Compose v2 where the local apple/container structured record and follow-stream APIs are available; released support waits for upstream apple/container PR acceptance.
- Service `logging.driver` and `logging.options` either map to apple/container logging policy primitives or reject before side effects with precise apple/container runtime-gap messages.

## References

- Docker Compose logs CLI reference: [docs.docker.com/reference/cli/docker/compose/logs](https://docs.docker.com/reference/cli/docker/compose/logs/).
- Docker Compose service `logging` reference: [docs.docker.com/reference/compose-file/services/#logging](https://docs.docker.com/reference/compose-file/services/#logging).
- apple/container repository: [github.com/apple/container](https://github.com/apple/container).
- apple/container public API docs: [apple.github.io/container/documentation](https://apple.github.io/container/documentation/).
