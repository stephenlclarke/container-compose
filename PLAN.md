# container-compose Log Compliance Plan

This plan tracks the log-related work needed for `container-compose` to match Docker Compose v2 local-development behavior where [`apple/container`](https://github.com/apple/container) exposes equivalent runtime primitives.

Assessment timestamp: `2026-06-19 06:19:29 BST`.

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

`container-compose` currently calls `ContainerClient.logs(id:options:)` through `ContainerClientLogManager` for raw replay and follow. Static raw replay passes `tail`, `--since`, `--until`, and rotated replay requests to apple/container where available. Followed raw logs on the local `logs-integration` stack poll merged rotated replay snapshots and emit only the newly appended suffix, so rename-based local rotation does not strand the follower on an old file handle. For timestamped output and time-window follow, the plugin consumes `ContainerClient.logRecords(id:options:)` with rotated replay enabled and follows merged structured record snapshots with the same overlap cursor. Raw followed streams use direct container status to exit when the target stops. Structured followed streams use direct container status to keep partial records buffered while the target is live, then flush a final unterminated record once the target stops.

[`apple/container`](https://github.com/apple/container) currently exposes `container logs [--boot] [--follow] [-n <n>] <container-id>` and `ContainerClient.logs(id:)` upstream. The local `logs-integration` branch adds `ContainerLogOptions`, static filtered replay, byte-preserving raw log tail filtering, timestamped structured log storage, `ContainerClient.logRecords(id:options:)`, `ContainerClient.logRecordFile(id:)`, Unix timestamp parsing for `container logs --since/--until`, writer-level local log rotation for configured max size and file count, `container create/run --log-opt max-size=<size>` and `--log-opt max-file=<count>` local rotation policy parsing, static rotated raw and structured replay, static `container logs --timestamps` CLI rendering, followed `container logs --follow --timestamps/--since/--until` CLI rendering from structured records, rotated raw/structured follow by polling merged replay snapshots through the direct APIs, direct-status stop-boundary exit for raw follow, and stop-boundary flushing for final unterminated followed structured records. Those local APIs give the plugin enough data to implement timestamped, time-filtered, and rotated follow behavior, but released support still depends on upstream review and acceptance of the apple/container API shape.

## Related Compose Implementations

The work in this repository overlaps with two public Compose efforts called out in [`apple/container#1752`](https://github.com/apple/container/issues/1752#issuecomment-2999970912). The intent here is to track overlap and avoid duplicated upstream effort while keeping this repo focused on a standalone `container compose` plugin shape.

### full-chaos/container-compose

Repository: [`full-chaos/container-compose`](https://github.com/full-chaos/container-compose)

Container fork used: [`full-chaos/container`](https://github.com/full-chaos/container), pinned from `Package.swift` to branch [`tier2-fork-patches`](https://github.com/full-chaos/container/tree/tier2-fork-patches). Its README also describes an opt-in [`dev`](https://github.com/full-chaos/container/tree/dev) branch for fork-forward runtime features.

Overlap: <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square">

- Implements a broad Docker Compose-like CLI and runtime abstraction layer for Apple containers.
- Tracks fork-forward runtime gaps that also matter to this repo, including log options, events, restart policy, healthcheck observation, richer IPAM, process flag factoring, and resource controls.
- [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11) overlaps directly with this log plan by adding `ContainerLogOptions` for `since` and `timestamps` to `ContainerClient.logs`.

How this repo complements it: <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square">

- This repo keeps Compose normalization behind `compose-go` so Docker Compose v2 merge, interpolation, profile, include, and extension semantics stay aligned with Docker's maintained implementation.
- This repo is shaped as a `container compose` plugin using the current plugin install layout, with direct `apple/container` APIs used wherever available.
- The local log work goes beyond raw line filtering by adding structured timestamped records and a `ContainerClient.logRecords` API. That should be compared with `full-chaos/container#11` so any upstream PR can reuse compatible naming and wire semantics rather than creating a competing API shape.

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
      <td><img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> Static and followed <code>--timestamps</code>, <code>--since</code>, and <code>--until</code> are implemented on the local integration stack through structured records. Followed structured logs poll merged rotated record snapshots, emit only newly appended records, and flush final unterminated records when the target stops. Released support still depends on upstream apple/container PR acceptance.</td>
    </tr>
    <tr>
      <td>Service logging drivers/options</td>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"></td>
      <td><img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> File-backed <code>json-file</code> and <code>local</code> logging map to apple/container local stdio capture. <code>none</code> maps to disabled persisted capture on the local integration stack. Local <code>max-size</code>/<code>max-file</code> options now map to apple/container <code>--log-opt</code> flags; static and followed rotated local replay work on the local stack. Remote drivers remain open.</td>
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
- Calls `ContainerClient.logs(id:options:)` through `ContainerClientLogManager`.
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
- <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> This repo's plugin-side fan-out, service/replica aggregation, and rotated snapshot cursor tests can validate shared lower-level log-follow primitives used by command-oriented Compose implementations.

Docker Compose surface: `docker compose logs --follow [SERVICE...]`.

Current `container-compose` behavior:

- Supports `--follow` for resolved service container targets.
- Starts multiple selected service and replica streams concurrently with a throwing task group.
- Surfaces stream failures instead of letting one followed stream starve later targets.
- Polls merged raw log replay snapshots through `ContainerClient.logs(id:options:)` with rotated replay enabled, emits only appended complete log records, and flushes an unterminated final record when direct runtime status shows the target is no longer live.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Upstream `container logs --follow <container-id>` follows one container log file.
- The local `logs-integration` branch can also follow merged rotated raw replay snapshots through `ContainerClient.logs(id:options:)` with `includeRotated: true`, and exits when direct container status shows the target is no longer live.
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
- Passes static timestamp filters through the direct apple/container log API.
- Uses structured `ContainerClient.logRecords(id:options:)` on the local integration stack to render static `logs --timestamps` without parsing timestamps from application output.
- Uses merged rotated `ContainerClient.logRecords(id:options:)` snapshots on the local integration stack for initial replay plus followed structured records for `--timestamps --follow` and `--follow` combined with `--since` or `--until`.
- Uses merged rotated `ContainerClient.logs(id:options:)` snapshots for unfiltered raw follow and emits only the appended suffix between snapshots.
- Stops structured follow when the `--until` deadline is reached, even when no new log records arrive.
- Buffers split structured records while the followed target is live, then flushes the final unterminated structured record when direct runtime status shows the target is no longer live.
- Cannot reconstruct capture timestamps for logs produced before the structured record store exists.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Upstream exposes raw stdio and boot log file handles.
- The local `logs-integration` branch exposes static `tail`, `since`, and `until` filtering through `ContainerClient.logs(id:options:)`, with raw `tail` filtering performed without requiring UTF-8 decoding.
- The local `logs-integration` branch accepts RFC 3339 timestamps and Unix timestamps in seconds with optional fractional seconds for `container logs --since` and `--until`.
- The local `logs-integration` branch stores timestamped runtime records and exposes `ContainerClient.logRecords(id:options:)` with timestamp, stream, and raw bytes for static replay.
- The local `logs-integration` branch exposes `ContainerClient.logRecordFile(id:)` for clients that want direct structured JSONL file access.
- The local `logs-integration` branch renders static `container logs --timestamps` output through structured records with tail applied after runtime chunks are rebuilt into log lines.
- The local `logs-integration` branch renders followed `container logs --timestamps`, `--since`, and `--until` output through merged rotated structured record snapshots, renders plain unfiltered `container logs --follow` through merged rotated raw snapshots, exits raw follow when direct container status shows the target is no longer live, and flushes final unterminated followed structured records at the same stop boundary.
- Does not yet have upstream-reviewed cursor, truncation, or retention semantics for long-lived merged replay follow clients.

Missing behavior:

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Static and followed `--timestamps`, `--since`, and `--until` work on the local integration stack, but still need upstream apple/container PR acceptance before they can be treated as released support.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> A stable record format plus merged replay cursor behavior now exist locally; upstream review needs to confirm cursor, retention, and truncation behavior before plugin releases can depend on it.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Capture timestamps are unavailable for containers that only have legacy raw stdio logs.

Implementation direction:

- Split the local [`apple/container`](https://github.com/apple/container) log work into small upstream PRs: log options, filtered static replay, structured timestamped record storage, structured record retrieval, static rotated replay, and rotated merged-replay follow.
- Compare the upstreamable API shape with [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11) before opening PRs so both Compose implementations can converge on one runtime contract.
- Add golden behavior tests using RFC 3339 timestamps, Unix timestamps, relative durations, followed timestamp output, and combined `--since`/`--until` windows after the upstream API shape settles.

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
- The local `logs-integration` branch adds a typed local logging policy, treats `container create/run --log-driver json-file` and `--log-driver local` as local stdio capture aliases, supports disabled persisted capture through `--log-driver none`, parses `container create/run --log-opt max-size=<size>` and `--log-opt max-file=<count>` into the local rotation policy, honors configured local `maxSizeInBytes` / `maxFileCount` at the runtime writer, and exposes static plus followed rotated raw and structured replay through direct log options.
- Does not expose Docker-compatible remote logging driver selection or remote logging backends.

Missing behavior:

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Disabled persisted capture works on the local integration stack but still depends on upstream apple/container PR acceptance before it can be treated as released support.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Writer-level local rotation, CLI option parsing, Compose option mapping, static rotated replay, and followed rotated replay work on the local integration stack for `max-size` and `max-file`, but still depend on upstream API review before they can be treated as released support.
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
- The local `logs-integration` branch also stores structured records with stdout/stderr stream metadata and per-record capture timestamps.

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
5. <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> Upstream the local apple/container timestamped structured log records, direct retrieval API, and rotated merged-replay follow API.
6. <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> Propose apple/container service logging policy primitives for remote drivers and remaining non-local logging options.
7. <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> Revisit service `logging` mappings beyond local file-backed drivers after upstream runtime APIs exist.

## Acceptance Criteria

- `container compose logs` with no services prints logs for every Compose-managed service container in the project.
- `container compose logs SERVICE` prints logs for every replica of that service unless `--index` narrows the target.
- `container compose logs --follow` streams all selected containers concurrently and surfaces stream failures.
- Default output includes Compose-style service/replica prefixes and optional color; `--no-log-prefix` and `--no-color` alter real behavior.
- `--tail` applies independently to each selected container.
- Blank lines and trailing newline behavior match Docker Compose v2 fixtures.
- Static and followed `--timestamps`, `--since`, and `--until` match Docker Compose v2 where the local apple/container structured record and record-file APIs are available; released support waits for upstream apple/container PR acceptance.
- Service `logging.driver` and `logging.options` either map to apple/container logging policy primitives or reject before side effects with precise apple/container runtime-gap messages.

## References

- Docker Compose logs CLI reference: [docs.docker.com/reference/cli/docker/compose/logs](https://docs.docker.com/reference/cli/docker/compose/logs/).
- Docker Compose service `logging` reference: [docs.docker.com/reference/compose-file/services/#logging](https://docs.docker.com/reference/compose-file/services/#logging).
- apple/container repository: [github.com/apple/container](https://github.com/apple/container).
- apple/container public API docs: [apple.github.io/container/documentation](https://apple.github.io/container/documentation/).
