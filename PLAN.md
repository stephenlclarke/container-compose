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

## Current Runtime Evidence

`container-compose` currently calls `ContainerClient.logs(id:options:)` through `ContainerClientLogManager` when static replay filters are present, while retaining `ContainerClient.logs(id:)` compatibility for unfiltered streams. It reads the first returned file handle as the container stdio log, passes static `tail`, `--since`, and `--until` filters to apple/container where available, and follows appended lines with a file readability handler.

[`apple/container`](https://github.com/apple/container) currently exposes `container logs [--boot] [--follow] [-n <n>] <container-id>` and `ContainerClient.logs(id:)`. The server opens two file handles for an existing container bundle: stdio logs and boot logs. The runtime comment says logs only require the container bundle and files to exist, not that the container is currently running.

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
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"></td>
      <td>Default output prefixes each line with service/index identity, and <code>--no-log-prefix</code> emits raw output. Color remains intentionally monochrome.</td>
    </tr>
    <tr>
      <td>Timestamp and time-window filtering</td>
      <td><img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"></td>
      <td>Docker Compose supports <code>--timestamps</code>, <code>--since</code>, and <code>--until</code>. apple/container exposes raw log files without per-record timestamps.</td>
    </tr>
    <tr>
      <td>Service logging drivers/options</td>
      <td><img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"></td>
      <td>Compose service <code>logging.driver</code> and <code>logging.options</code> need runtime logging policy primitives that apple/container does not currently expose.</td>
    </tr>
    <tr>
      <td>Exact byte/line fidelity</td>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"></td>
      <td>container-compose emits UTF-8 text and drops empty split lines in tail/follow paths. Docker Compose should preserve log event boundaries and blank output more faithfully.</td>
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

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Preserve blank log lines and partial trailing lines consistently while following.

Completed implementation:

- `ComposeOrchestrator.logs` resolves the full target set first, then fans out multiple `ContainerLogManaging.logs` streams with a task group.
- Regression coverage proves a scaled service starts both followed replicas before either stream is released.

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

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Empty-line fidelity should be checked against Docker Compose before this is called fully compliant.

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

Status: <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">

Docker Compose surface: default prefixed output, `--no-log-prefix`, and `--no-color`.

Current `container-compose` behavior:

- Prefixes default log output as <code>service-index | line</code>.
- Prefixes each line of a multiline emitted log chunk.
- Supports `--no-log-prefix` to emit raw log output.
- Accepts `--no-color`; current output remains monochrome in all modes.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Exposes raw container stdio logs.
- Does not attach Compose service names, replica indexes, or color metadata to log records.

Missing behavior:

- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Color should be enabled only when appropriate for terminal output and disabled by `--no-color`, `--ansi never`, or non-interactive output.

Completed implementation:

- `ComposeOrchestrator.logs` wraps the per-target emitter with a service/index prefix policy before handing it to `ContainerLogManaging`.
- `--no-log-prefix` bypasses that wrapper and preserves raw log output.
- Tests cover prefixed output, multiline prefixing, raw output, and scaled replica prefixes.

Remaining plugin work:

- Add color policy that honors `--no-color`, `--ansi never`, and non-interactive output.

### L6. Timestamps, `--since`, and `--until`

Status: <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">

Docker Compose surface: `docker compose logs --timestamps`, `docker compose logs --since VALUE`, and `docker compose logs --until VALUE`.

Current `container-compose` behavior:

- Exposes `--since` and `--until` on `compose logs`.
- Accepts RFC 3339 timestamps and relative durations such as `30m`, `2h`, or `1h30m`.
- Passes static timestamp filters through the direct apple/container log API.
- Rejects `--timestamps` because historical raw stdio logs do not contain capture timestamps.
- Rejects `--follow` combined with `--since` or `--until` because the current direct API returns filtered snapshots, not filtered follow streams.
- Cannot reconstruct historical capture timestamps from the current raw stdio file.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Exposes raw stdio and boot log file handles.
- The local log-options work-in-progress exposes static `tail`, `since`, and `until` filtering through `ContainerClient.logs(id:options:)`.
- Does not expose timestamped log records, a log cursor, filtered follow streams, or stdout/stderr stream identity.

Missing behavior:

- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Per-record log timestamps at capture time.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Static timestamp filtering is available through the local apple/container direct API work, but only for log lines with parseable timestamp prefixes.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Runtime or API support for filtered follow streams.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> A stable record format that can preserve timestamps without corrupting raw application output.

Implementation direction:

- Open an [`apple/container`](https://github.com/apple/container) runtime PR for timestamped log records or a second structured log stream.
- After the runtime exposes timestamps, implement `--timestamps` in `container-compose`.
- After the runtime exposes filtered streaming, allow `--follow` together with `--since` and `--until`.
- Add golden behavior tests using absolute timestamps, relative durations, and combined `--since`/`--until` windows.

### L7. Service Logging Driver and Options

Status: <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">

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

Status: <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">

Docker Compose surface: raw application stdout/stderr content displayed through `docker compose logs`.

Current `container-compose` behavior:

- Requires UTF-8 log data.
- Trims trailing newlines in full replay.
- Filters empty lines in tail and follow paths.
- Emits log chunks as complete strings rather than structured log records.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Stores a merged stdio file and returns a file handle.
- Does not expose stdout/stderr stream metadata or per-record boundaries.

Missing behavior:

- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Preserve intentional blank log lines when reading and following.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Decide whether non-UTF-8 logs should fail, pass bytes through, or match Docker's replacement behavior.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Preserve stdout/stderr stream identity if future Compose behavior requires it for formatting or filtering.

Implementation direction:

- Add Docker Compose comparison fixtures for blank lines, trailing newline behavior, and non-UTF-8 bytes.
- Fix plugin-side blank-line handling where raw file handles already contain enough information.
- Track stream identity as upstream runtime work unless apple/container adds structured log records.

## Suggested Work Order

1. <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Implement all-replica target resolution for `logs`.
2. <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> Implement concurrent multi-service and multi-replica follow.
3. <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Add default Compose prefixes, `--no-log-prefix` behavior, and color policy.
4. <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Fix blank-line and line-boundary fidelity that can be solved from current raw file handles.
5. <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Propose apple/container timestamped structured log records.
6. <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Propose apple/container service logging policy primitives.
7. <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Revisit `--timestamps`, filtered follow, and service `logging` mappings after upstream runtime APIs exist.

## Acceptance Criteria

- `container compose logs` with no services prints logs for every Compose-managed service container in the project.
- `container compose logs SERVICE` prints logs for every replica of that service unless `--index` narrows the target.
- `container compose logs --follow` streams all selected containers concurrently and surfaces stream failures.
- Default output includes Compose-style service/replica prefixes and optional color; `--no-log-prefix` and `--no-color` alter real behavior.
- `--tail` applies independently to each selected container.
- Blank lines and trailing newline behavior match Docker Compose v2 fixtures.
- `--timestamps`, `--since`, and `--until` either match Docker Compose v2 or reject with precise apple/container runtime-gap messages until timestamped runtime records exist.
- Service `logging.driver` and `logging.options` either map to apple/container logging policy primitives or reject before side effects with precise apple/container runtime-gap messages.

## References

- Docker Compose logs CLI reference: [docs.docker.com/reference/cli/docker/compose/logs](https://docs.docker.com/reference/cli/docker/compose/logs/).
- Docker Compose service `logging` reference: [docs.docker.com/reference/compose-file/services/#logging](https://docs.docker.com/reference/compose-file/services/#logging).
- apple/container repository: [github.com/apple/container](https://github.com/apple/container).
- apple/container public API docs: [apple.github.io/container/documentation](https://apple.github.io/container/documentation/).
