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

`container-compose` currently calls `ContainerClient.logs(id:)` through `ContainerClientLogManager`. It reads the first returned file handle as the container stdio log, supports plugin-side `tail`, and follows appended lines with a file readability handler.

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
      <td><code>--follow</code>, <code>--tail N</code>, <code>-n N</code>, and <code>--tail all</code> are wired for one selected runtime container.</td>
    </tr>
    <tr>
      <td>Replica and service aggregation</td>
      <td><img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"></td>
      <td>Docker Compose shows all selected service containers by default. container-compose currently targets one index unless <code>--index</code> is supplied.</td>
    </tr>
    <tr>
      <td>Multi-service follow</td>
      <td><img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"></td>
      <td>Docker Compose follows all selected services together. container-compose loops services sequentially, so the first followed stream can block later services.</td>
    </tr>
    <tr>
      <td>Compose log presentation</td>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"></td>
      <td><code>--no-color</code> and <code>--no-log-prefix</code> are accepted, but default Docker Compose service/index prefixes and colors are not implemented.</td>
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
- Calls `ContainerClient.logs(id:)` through `ContainerClientLogManager`.
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

- Supports `--follow` for a single resolved service container.
- Uses a file readability handler to emit appended UTF-8 log lines.

Current [`apple/container`](https://github.com/apple/container) behavior:

- `container logs --follow <container-id>` follows one container log file.
- The direct API exposes the file handle that makes the current plugin implementation possible.

Missing behavior:

- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Follow all selected services and replicas concurrently instead of looping sequentially.
- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Keep one failed stream from silently starving or hiding other selected streams.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Preserve blank log lines and partial trailing lines consistently while following.

Implementation direction:

- Change `ComposeOrchestrator.logs` to resolve the full target set first, then fan in multiple `ContainerLogManaging.logs` streams with task-group cancellation.
- Add tests for `logs --follow` with two services and a scaled service where both streams emit.

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

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Tail should apply independently to every selected container once all-replica and multi-service aggregation is implemented.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Empty-line fidelity should be checked against Docker Compose before this is called fully compliant.

### L4. Service and Replica Selection

Status: <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square">

Docker Compose surface: `docker compose logs [SERVICE...]` and `docker compose logs --index N SERVICE`.

Current `container-compose` behavior:

- Supports service name filtering.
- Supports `--index N` for one selected replica.
- Defaults to index `1` for every selected service.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Supports direct lookup by container ID through existing list/get APIs and direct log handles by ID.
- Does not need a special multi-replica primitive for plugin-side enumeration because Compose labels and deterministic names already identify service replicas.

Missing behavior:

- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Without `--index`, Docker Compose should include every existing replica for each selected service.
- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> No-service selection should include all project services and their replicas, not only index `1`.
- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Selection should include existing Compose-managed service containers even when scale was changed outside the current file, matching the rest of the project discovery behavior where safe.

Implementation direction:

- Reuse the existing project-scoped container discovery and replica-index helpers already used by `ps`, `exec`, `cp`, `port`, and `wait`.
- Make `--index` mutually narrow the target set only for selected services.
- Add regression tests for scaled services, multiple selected services, and no-service selection.

### L5. Prefixes, Colors, and `--no-log-prefix`

Status: <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">

Docker Compose surface: default prefixed output, `--no-log-prefix`, and `--no-color`.

Current `container-compose` behavior:

- Accepts `--no-color`.
- Accepts `--no-log-prefix`.
- Emits raw log lines without service prefixes or color in all modes.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Exposes raw container stdio logs.
- Does not attach Compose service names, replica indexes, or color metadata to log records.

Missing behavior:

- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Default output should prefix each line with the Compose service/container identity.
- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Prefixes should distinguish scaled replicas in the same way Docker Compose users expect.
- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> `--no-log-prefix` should suppress an otherwise-present prefix instead of being an accepted no-op.
- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Color should be enabled only when appropriate for terminal output and disabled by `--no-color`, `--ansi never`, or non-interactive output.

Implementation direction:

- Add a `ComposeLogFormatter` that receives `(service, index, line)` records and applies prefix/color policy.
- Keep raw mode available for `--no-log-prefix`.
- Add tests for prefixed default output, `--no-log-prefix`, `--no-color`, and scaled replica prefixes.

### L6. Timestamps, `--since`, and `--until`

Status: <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">

Docker Compose surface: `docker compose logs --timestamps`, `docker compose logs --since VALUE`, and `docker compose logs --until VALUE`.

Current `container-compose` behavior:

- Does not expose these options on `compose logs`.
- Cannot reconstruct historical capture timestamps from the current raw stdio file.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Exposes raw stdio and boot log file handles.
- Does not expose timestamped log records, a log cursor, or server-side since/until filtering.

Missing behavior:

- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Per-record log timestamps at capture time.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Runtime or API support for filtering logs by absolute timestamp and relative duration.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> A stable record format that can preserve timestamps without corrupting raw application output.

Implementation direction:

- Open an [`apple/container`](https://github.com/apple/container) runtime PR for timestamped log records or a second structured log stream.
- After the runtime exposes timestamps, add CLI parsing for `--timestamps`, `--since`, and `--until` in `container-compose`.
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

1. <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Implement all-replica target resolution for `logs`.
2. <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Implement concurrent multi-service and multi-replica follow.
3. <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Add default Compose prefixes, `--no-log-prefix` behavior, and color policy.
4. <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> Fix blank-line and line-boundary fidelity that can be solved from current raw file handles.
5. <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Propose apple/container timestamped structured log records.
6. <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> Propose apple/container service logging policy primitives.
7. <img alt="OUTSTANDING" src="https://img.shields.io/badge/OUTSTANDING-6B7280?style=flat-square"> Revisit `--timestamps`, `--since`, `--until`, and service `logging` mappings after upstream runtime APIs exist.

## Acceptance Criteria

- `container compose logs` with no services prints logs for every Compose-managed service container in the project.
- `container compose logs SERVICE` prints logs for every replica of that service unless `--index` narrows the target.
- `container compose logs --follow` streams all selected containers concurrently and stops cleanly on cancellation.
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
