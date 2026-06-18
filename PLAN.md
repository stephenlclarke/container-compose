# container-compose Log Compliance Plan

This plan tracks the log-related work needed for `container-compose` to match Docker Compose v2 local-development behavior where [`apple/container`](https://github.com/apple/container) exposes equivalent runtime primitives.

Assessment timestamp: `2026-06-18 21:05:51 BST`.

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
- <img alt="OVERLAPS OTHER IMPL" src="https://img.shields.io/badge/OVERLAPS%20OTHER%20IMPL-0891B2?style=flat-square">: another Compose implementation is working in the same problem area and should be reviewed before upstreaming.
- <img alt="COMPLEMENTS OTHER IMPL" src="https://img.shields.io/badge/COMPLEMENTS%20OTHER%20IMPL-7C3AED?style=flat-square">: this repository adds a compatible piece, different architecture boundary, or upstreamable slice that can help the other implementation.

## Current Runtime Evidence

`container-compose` currently calls `ContainerClient.logs(id:options:)` through `ContainerClientLogManager` when static raw replay filters are present, while retaining `ContainerClient.logs(id:)` compatibility for unfiltered streams. It reads the first returned file handle as the container stdio log, passes static `tail`, `--since`, and `--until` filters to apple/container where available, and follows appended lines with a file readability handler. On the local `logs-integration` stack it also consumes `ContainerClient.logRecords(id:options:)` for static `logs --timestamps`.

[`apple/container`](https://github.com/apple/container) currently exposes `container logs [--boot] [--follow] [-n <n>] <container-id>` and `ContainerClient.logs(id:)` upstream. The local `logs-integration` branch adds `ContainerLogOptions`, static filtered replay, timestamped structured log storage, and `ContainerClient.logRecords(id:options:)`. Followed structured records and filtered follow streams are still runtime/API gaps.

## Related Compose Implementations

The work in this repository overlaps with two public Compose efforts called out in [`apple/container#1752`](https://github.com/apple/container/issues/1752#issuecomment-2999970912). The intent here is to track overlap and avoid duplicated upstream effort while keeping this repo focused on a standalone `container compose` plugin shape.

### full-chaos/container-compose

Repository: [`full-chaos/container-compose`](https://github.com/full-chaos/container-compose)

Container fork used: [`full-chaos/container`](https://github.com/full-chaos/container), pinned from `Package.swift` to branch [`tier2-fork-patches`](https://github.com/full-chaos/container/tree/tier2-fork-patches). Its README also describes an opt-in [`dev`](https://github.com/full-chaos/container/tree/dev) branch for fork-forward runtime features.

Overlap: <img alt="OVERLAPS OTHER IMPL" src="https://img.shields.io/badge/OVERLAPS%20OTHER%20IMPL-0891B2?style=flat-square">

- Implements a broad Docker Compose-like CLI and runtime abstraction layer for Apple containers.
- Tracks fork-forward runtime gaps that also matter to this repo, including log options, events, restart policy, healthcheck observation, richer IPAM, process flag factoring, and resource controls.
- [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11) overlaps directly with this log plan by adding `ContainerLogOptions` for `since` and `timestamps` to `ContainerClient.logs`.

How this repo complements it: <img alt="COMPLEMENTS OTHER IMPL" src="https://img.shields.io/badge/COMPLEMENTS%20OTHER%20IMPL-7C3AED?style=flat-square">

- This repo keeps Compose normalization behind `compose-go` so Docker Compose v2 merge, interpolation, profile, include, and extension semantics stay aligned with Docker's maintained implementation.
- This repo is shaped as a `container compose` plugin using the current plugin install layout, with direct `apple/container` APIs used wherever available.
- The local log work goes beyond raw line filtering by adding structured timestamped records and a `ContainerClient.logRecords` API. That should be compared with `full-chaos/container#11` so any upstream PR can reuse compatible naming and wire semantics rather than creating a competing API shape.

### Mcrich23/Container-Compose

Repository: [`Mcrich23/Container-Compose`](https://github.com/Mcrich23/Container-Compose)

Container fork used: the public `Container-Compose` package currently depends on [`apple/container`](https://github.com/apple/container) from `1.0.0`. The related fork [`Mcrich23/container`](https://github.com/Mcrich23/container) contains an [`add-compose`](https://github.com/Mcrich23/container/tree/add-compose) branch with the earlier in-tree plugin work and an [`add-command-option-group-function-macro`](https://github.com/Mcrich23/container/tree/add-command-option-group-function-macro) branch related to plugin OptionGroup passthrough.

Overlap: <img alt="OVERLAPS OTHER IMPL" src="https://img.shields.io/badge/OVERLAPS%20OTHER%20IMPL-0891B2?style=flat-square">

- Provides the original Swift Compose implementation lineage that later fed discussion around plugin support and OptionGroup passthrough.
- Uses `ContainerCommands` heavily, which overlaps with the plugin ergonomics discussion in [`apple/container#1410`](https://github.com/apple/container/discussions/1410), [`apple/container#633`](https://github.com/apple/container/issues/633), and [`apple/container#717`](https://github.com/apple/container/pull/717).
- Covers basic Compose model structures, command wiring, service dependencies, volumes, networks, and logging surfaces.

How this repo complements it: <img alt="COMPLEMENTS OTHER IMPL" src="https://img.shields.io/badge/COMPLEMENTS%20OTHER%20IMPL-7C3AED?style=flat-square">

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
      <td>Static <code>--timestamps</code>, <code>--since</code>, and <code>--until</code> are implemented on the local integration stack. Timestamped follow and filtered follow streams remain apple/container gaps.</td>
    </tr>
    <tr>
      <td>Service logging drivers/options</td>
      <td><img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"></td>
      <td>Compose service <code>logging.driver</code> and <code>logging.options</code> need runtime logging policy primitives that apple/container does not currently expose.</td>
    </tr>
    <tr>
      <td>Exact byte/line fidelity</td>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"></td>
      <td>container-compose now preserves blank UTF-8 line records and followed partial lines. Full byte fidelity and stdout/stderr identity still need runtime support or a deliberate compatibility decision.</td>
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
- Reads the stdio file handle and emits existing UTF-8 log data.
- Supports stopped-container replay when the apple/container bundle and log files still exist.

Current [`apple/container`](https://github.com/apple/container) behavior:

- `container logs <container-id>` reads the same stdio log file handle.
- `ContainerClient.logs(id:)` returns stdio and boot log handles.

Remaining work:

- None for the basic one-container raw replay path.

### L2. Follow Mode

Status: <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">

Docker Compose surface: `docker compose logs --follow [SERVICE...]`.

Current `container-compose` behavior:

- Supports `--follow` for resolved service container targets.
- Starts multiple selected service and replica streams concurrently with a throwing task group.
- Surfaces stream failures instead of letting one followed stream starve later targets.
- Uses a file readability handler to emit appended UTF-8 log lines.

Current [`apple/container`](https://github.com/apple/container) behavior:

- `container logs --follow <container-id>` follows one container log file.
- The direct API exposes the file handle that makes the current plugin implementation possible.

Remaining work:

- None known for plugin-side follow fan-out and line splitting. Timestamped or structured follow filters remain apple/container work in later sections.

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

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Docker Compose comparison fixtures should still be added for unusual trailing-newline and byte-stream cases.

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

Status: <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> <img alt="OVERLAPS OTHER IMPL" src="https://img.shields.io/badge/OVERLAPS%20OTHER%20IMPL-0891B2?style=flat-square"> <img alt="COMPLEMENTS OTHER IMPL" src="https://img.shields.io/badge/COMPLEMENTS%20OTHER%20IMPL-7C3AED?style=flat-square">

Docker Compose surface: `docker compose logs --timestamps`, `docker compose logs --since VALUE`, and `docker compose logs --until VALUE`.

Current `container-compose` behavior:

- Exposes `--since` and `--until` on `compose logs`.
- Accepts RFC 3339 timestamps and relative durations such as `30m`, `2h`, or `1h30m`.
- Passes static timestamp filters through the direct apple/container log API.
- Uses structured `ContainerClient.logRecords(id:options:)` on the local integration stack to render static `logs --timestamps` without parsing timestamps from application output.
- Rejects `--follow` combined with `--since` or `--until` because the current direct API returns filtered snapshots, not filtered follow streams.
- Rejects `--timestamps --follow` because the current direct API returns timestamped record snapshots, not timestamped record streams.
- Cannot reconstruct capture timestamps for logs produced before the structured record store exists.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Upstream exposes raw stdio and boot log file handles.
- The local `logs-integration` branch exposes static `tail`, `since`, and `until` filtering through `ContainerClient.logs(id:options:)`.
- The local `logs-integration` branch stores timestamped runtime records and exposes `ContainerClient.logRecords(id:options:)` with timestamp, stream, and raw bytes for static replay.
- Does not yet expose a log cursor, filtered follow streams, or structured followed record streams.

Missing behavior:

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Static `--timestamps`, `--since`, and `--until` work on the local integration stack, but still need upstream apple/container PR acceptance before they can be treated as released support.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Runtime or API support for filtered follow streams.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Runtime or API support for timestamped followed record streams.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> A stable record format now exists locally; upstream review needs to confirm the long-term shape before plugin releases can depend on it.

Implementation direction:

- Split the local [`apple/container`](https://github.com/apple/container) log work into small upstream PRs: log options, filtered static replay, structured timestamped record storage, and structured record retrieval.
- Compare the upstreamable API shape with [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11) before opening PRs so both Compose implementations can converge on one runtime contract.
- After the runtime exposes filtered streaming, allow `--follow` together with `--since` and `--until`.
- After the runtime exposes structured record streaming, allow `--timestamps --follow`.
- Add golden behavior tests using absolute timestamps, relative durations, and combined `--since`/`--until` windows.

### L7. Service Logging Driver and Options

Status: <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> <img alt="OVERLAPS OTHER IMPL" src="https://img.shields.io/badge/OVERLAPS%20OTHER%20IMPL-0891B2?style=flat-square">

Docker Compose surface: service `logging.driver`, `logging.options`, legacy `log_driver`, and legacy `log_opt`.

Current `container-compose` behavior:

- Rejects service logging driver/options before creating resources.
- Preserves the compatibility boundary in tests and `COMPATIBILITY.md`.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Captures container stdio to local runtime files.
- Does not expose Docker-compatible logging driver selection, logging options, rotation policy, or remote logging backends.

Missing behavior:

- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Runtime logging driver selection per container.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Driver-specific options such as rotation, max size, syslog endpoint, labels, or env inclusion.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Clear policy for unsupported Docker logging drivers on macOS.

Implementation direction:

- Open an [`apple/container`](https://github.com/apple/container) design discussion before mapping Compose logging policies, because this changes runtime storage and forwarding behavior.
- Keep `container-compose` rejection behavior until a real runtime policy exists.
- Add mapping tests only after the runtime API shape is known.

### L8. Exact Log Fidelity

Status: <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> <img alt="COMPLEMENTS OTHER IMPL" src="https://img.shields.io/badge/COMPLEMENTS%20OTHER%20IMPL-7C3AED?style=flat-square">

Docker Compose surface: raw application stdout/stderr content displayed through `docker compose logs`.

Current `container-compose` behavior:

- Requires UTF-8 log data.
- Preserves blank line records in full replay, local tailing, and followed streams.
- Buffers followed output so split lines are not emitted until complete, and flushes a final partial line when the stream closes.
- Emits UTF-8 log text chunks rather than structured stdout/stderr records.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Stores a merged stdio file and returns a file handle.
- Does not expose stdout/stderr stream metadata or per-record boundaries.

Missing behavior:

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Decide whether non-UTF-8 logs should fail, pass bytes through, or match Docker's replacement behavior.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Preserve stdout/stderr stream identity if future Compose behavior requires it for formatting or filtering.

Implementation direction:

- Add Docker Compose comparison fixtures for trailing newline behavior and non-UTF-8 bytes.
- Keep the plugin-side blank-line and split-line regression tests as guardrails.
- Track stream identity as upstream runtime work unless apple/container adds structured log records.

## Suggested Work Order

1. <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Implement all-replica target resolution for `logs`.
2. <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Implement concurrent multi-service and multi-replica follow.
3. <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Add default Compose prefixes, `--no-log-prefix` behavior, and color policy.
4. <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Fix blank-line and line-boundary fidelity that can be solved from current raw file handles.
5. <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> <img alt="OVERLAPS OTHER IMPL" src="https://img.shields.io/badge/OVERLAPS%20OTHER%20IMPL-0891B2?style=flat-square"> <img alt="COMPLEMENTS OTHER IMPL" src="https://img.shields.io/badge/COMPLEMENTS%20OTHER%20IMPL-7C3AED?style=flat-square"> Upstream the local apple/container timestamped structured log records and direct retrieval API.
6. <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> <img alt="OVERLAPS OTHER IMPL" src="https://img.shields.io/badge/OVERLAPS%20OTHER%20IMPL-0891B2?style=flat-square"> Propose apple/container service logging policy primitives.
7. <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> <img alt="COMPLEMENTS OTHER IMPL" src="https://img.shields.io/badge/COMPLEMENTS%20OTHER%20IMPL-7C3AED?style=flat-square"> Revisit timestamped follow, filtered follow, and service `logging` mappings after upstream runtime APIs exist.

## Acceptance Criteria

- `container compose logs` with no services prints logs for every Compose-managed service container in the project.
- `container compose logs SERVICE` prints logs for every replica of that service unless `--index` narrows the target.
- `container compose logs --follow` streams all selected containers concurrently and surfaces stream failures.
- Default output includes Compose-style service/replica prefixes and optional color; `--no-log-prefix` and `--no-color` alter real behavior.
- `--tail` applies independently to each selected container.
- Blank lines and trailing newline behavior match Docker Compose v2 fixtures.
- Static `--timestamps`, `--since`, and `--until` match Docker Compose v2 where the local apple/container structured record API is available; follow combinations reject with precise apple/container runtime-gap messages until timestamped and filtered runtime streams exist.
- Service `logging.driver` and `logging.options` either map to apple/container logging policy primitives or reject before side effects with precise apple/container runtime-gap messages.

## References

- Docker Compose logs CLI reference: [docs.docker.com/reference/cli/docker/compose/logs](https://docs.docker.com/reference/cli/docker/compose/logs/).
- Docker Compose service `logging` reference: [docs.docker.com/reference/compose-file/services/#logging](https://docs.docker.com/reference/compose-file/services/#logging).
- apple/container repository: [github.com/apple/container](https://github.com/apple/container).
- apple/container public API docs: [apple.github.io/container/documentation](https://apple.github.io/container/documentation/).
