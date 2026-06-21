# container-compose Log Compliance Plan

This plan tracks the log-related work needed for `container-compose` to match Docker Compose v2 local-development behavior where [`apple/container`](https://github.com/apple/container) exposes equivalent runtime primitives.

Assessment timestamp: `2026-06-21 22:51:12 BST`.

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

`container-compose` currently calls `ContainerClient.logs(id:options:replay:)` through `ContainerClientLogManager` for raw replay and follow. Static raw replay passes `tail`, `--since`, `--until`, and rotated replay requests to apple/container where available. Static timestamped output and time-window rendering pass `tail`, `--since`, and `--until` to `ContainerClient.logRecords(id:options:replay:)`, then render the returned structured records locally. The local apple/container branch now applies structured replay filters after logical log-line reconstruction, including split records, chunked records, and final complete EOF records. Followed structured logs now read the active `ContainerClient.logRecordFile(id:)` JSONL record file with a bounded cursor instead of repeatedly polling full merged snapshots. The extracted `logs-structured-record-api` branch exposes the active-file upstream surfaces as `ContainerClient.logRecords(id:options:)`, `ContainerClient.logRecordFile(id:)`, `ContainerLogRecord`, `ContainerLogOptions.tail/since/until`, XPC routes `containerLogRecords` and `containerLogRecordFile`, active raw bytes in `stdio.log`, and active structured JSON Lines records in `stdio.jsonl`. Followed raw logs still use plugin-side merged-snapshot polling to survive rename-based local rotation; this is useful for local validation, but a first-class apple/container rotation-aware follow cursor or stream remains upstream work before the behavior should be treated as an accepted runtime primitive.

[`apple/container`](https://github.com/apple/container) currently exposes `container logs [--boot] [--follow] [-n <n>] <container-id>` and `ContainerClient.logs(id:)` upstream. The local [`stephenlclarke/container` `logs-integration-chris`](https://github.com/stephenlclarke/container/tree/logs-integration-chris) branch is linear from upstream `main`, starts with Chris George's [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11) / [`apple/container#1592`](https://github.com/apple/container/pull/1592) retrieval-options direction, then tightens the API boundary by keeping `ContainerLogOptions` focused on retrieval filters, `ContainerLogReplayOptions` focused on rotated replay policy, and timestamp rendering as command/plugin presentation. The branch layers tail/until, static filtered replay, byte-preserving raw log tail filtering, Docker-compatible timestamp parsing, Docker-like line-framed structured log storage, `ContainerClient.logRecords(id:options:replay:)` with line-correct tail/since/until filtering, `ContainerClient.logRecordFile(id:)`, writer-level local log rotation for configured max size and file count, `container create/run --log-opt max-size=<size>` and `--log-opt max-file=<count>` local rotation policy parsing, static rotated raw and structured replay, static `container logs --timestamps` CLI rendering, and followed `container logs --follow --timestamps/--since/--until` CLI rendering from structured record files. The branch deliberately keeps CLI follow on active file/record handles instead of polling whole merged rotated snapshots. It is an integration proving branch, not the intended upstream PR shape; rotation-aware follow cursor or stream semantics are tracked as separate apple/container work.

## apple/container Log Direction

The container-side log work should be proposed upstream as small, reviewable PRs rather than as the full local integration branch. The intended sequence is:

1. Preserve Chris George's log retrieval direction from [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11) and [`apple/container#1592`](https://github.com/apple/container/pull/1592), while keeping retrieval filters, replay policy, and presentation flags on separate API boundaries.
2. Add `tail`, `since`, and `until` behavior only where apple/container can honor Docker's line-based contract after logical record reconstruction, with tests for split records, chunked records, final complete EOF records, and legacy raw records.
3. Add Docker-compatible timestamp parsing for RFC 3339/RFC 3339 nano, Unix seconds with optional fractional seconds, and relative durations.
4. Add structured log records and record-file replay with byte-fidelity, stdout/stderr identity, final-record EOF handling, and line-boundary tests.
5. Add static rotated raw and structured replay for local file-backed logging.
6. Add a bounded rotation-aware follow cursor or stream so `container-compose` does not need plugin-side merged-snapshot polling.
7. Add local logging policy support for `json-file`, `local`, `none`, `max-size`, and `max-file` separately from any future remote logging drivers.
8. Update `container-compose` after each accepted apple/container primitive lands, keeping Compose-specific formatting, prefixing, fan-out, and service selection inside this repository.

## Next Slab: Static Rotated Replay And Bounded Tail

Assumption for this slab: Chris George's [`apple/container#1592`](https://github.com/apple/container/pull/1592) and the follow-up [`apple/container#1764`](https://github.com/apple/container/pull/1764) / [`apple/container#1765`](https://github.com/apple/container/pull/1765) changes merge upstream. Treat those as the baseline runtime contract for `ContainerClient.logs(id:options:)`, `tail`, `since`, `until`, and Docker-compatible timestamp parsing. The next work should not reopen those decisions unless upstream review changes the accepted API shape.

Why this slab now: Docker Compose documents `logs --tail` as the number of lines to show from the end of logs for each container. Docker logging drivers document local retained log files through options such as `max-size` and `max-file`. The current local runtime integration can replay rotated files, but the next upstreamable change needs to make static rotated `tail` efficient and line-correct so `container logs -n 10` and `container compose logs --tail 10` do not require reading the entire retained history into memory.

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
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> [`logs-structured-record-storage`](https://github.com/stephenlclarke/container/tree/logs-structured-record-storage) and [`logs-structured-record-api`](https://github.com/stephenlclarke/container/tree/logs-structured-record-api): PR-ready fork branches that add active structured log storage and active structured record retrieval. They expose `stdio.log`, `stdio.jsonl`, `ContainerLogRecord`, `ContainerClient.logRecords(id:options:)`, and `ContainerClient.logRecordFile(id:)`; rotated replay and rotation-aware follow remain later PR slices.
- <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11): the fork-side precursor to #1592. Continue comparing API names and behavior so the two Compose efforts converge rather than fork the log contract.
- <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> [`apple/container#1736`](https://github.com/apple/container/pull/1736): peer Compose implementation. Use it for examples, test ideas, and CLI expectation comparison only; do not move Compose-specific policy into apple/container runtime PRs.

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
      <td><img alt="OUTSTANDING" src="https://img.shields.io/badge/OUTSTANDING-6B7280?style=flat-square"> Design and upstream a rotation-aware follow cursor or stream</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td></td>
      <td></td>
    </tr>
    <tr>
      <td colspan="4">Notes: replace plugin-side merged-snapshot polling with a runtime cursor that can follow active logs across rename-based rotation, detect truncation/retention loss, flush final partial records after container exit, and bound memory and file reads for long-running Compose follow sessions.</td>
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
      <td><img alt="OUTSTANDING" src="https://img.shields.io/badge/OUTSTANDING-6B7280?style=flat-square"> Upstream writer-level local log rotation</td>
      <td>2026-06-21 22:38:05 BST</td>
      <td></td>
      <td></td>
    </tr>
    <tr>
      <td colspan="4">Notes: split from local commit `06862b7` after the model and parser slices are settled. This should keep rotation in the runtime writer, preserve raw and structured files together, and pair with static rotated replay rather than Compose-specific follow polling.</td>
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
      <td colspan="4">Notes: `ContainerClientLogManager` already asks the direct API for `ContainerLogOptions(tail:)` and `ContainerLogReplayOptions(includeRotated: true)` on static raw logs. Prove the runtime honors that request with bounded static rotated replay, then keep the plugin as a thin fan-out and formatting layer. The remaining plugin-side merged-snapshot polling path should stay marked experimental until apple/container exposes a rotation-aware follow cursor or stream.</td>
    </tr>
    <tr>
      <td><img alt="OUTSTANDING" src="https://img.shields.io/badge/OUTSTANDING-6B7280?style=flat-square"> Switch timestamped logs to the upstream structured API</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td></td>
      <td></td>
    </tr>
    <tr>
      <td colspan="4">Notes: replace local-integration guards with the accepted `logRecords`/record-file API, render static and followed `--timestamps`, `--since`, and `--until` from runtime records, and keep legacy raw-log fallback behavior explicit for containers created before structured record support.</td>
    </tr>
    <tr>
      <td><img alt="OUTSTANDING" src="https://img.shields.io/badge/OUTSTANDING-6B7280?style=flat-square"> Replace raw rotated-follow polling with runtime cursor support</td>
      <td>2026-06-21 20:24:08 BST</td>
      <td></td>
      <td></td>
    </tr>
    <tr>
      <td colspan="4">Notes: remove the plugin-side repeated merged-snapshot polling path once apple/container exposes a rotation-aware cursor or stream. Keep Compose fan-out concurrency and per-service prefixing, but let the runtime own rotation/truncation and partial-record boundaries.</td>
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
      <td colspan="4">Notes: extend `examples/logging/compose.yml` and/or add a local comparison harness for `docker compose logs --tail` against `container compose logs --tail` on rotated `json-file` and `local` services. Keep live Docker comparisons optional in CI because they require Docker Engine, but record captured expected behavior for static fixtures. Cover RFC 3339/RFC 3339 nano, Unix timestamps, relative durations, `--tail 0 --follow`, negative tail, rotated replay, blank records, CRLF/CR separators, final partial lines, and selected-service multi-replica follow over time.</td>
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
      <td><img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> Static and followed <code>--timestamps</code>, <code>--since</code>, and <code>--until</code> are implemented on the local integration stack through structured records. Static rendering delegates line-correct tail and time filters to the direct apple/container record API, then renders the returned records. Followed structured logs read the active record file with a bounded cursor. Upstream acceptance still needs the structured API PRs and a rotation-aware follow cursor for long-lived clients.</td>
    </tr>
    <tr>
      <td>Service logging drivers/options</td>
      <td><img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"></td>
      <td><img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> File-backed <code>json-file</code> and <code>local</code> logging map to apple/container local stdio capture. <code>none</code> maps to disabled persisted capture on the local integration stack. Local <code>max-size</code>/<code>max-file</code> options now map to apple/container <code>--log-opt</code> flags; static rotated local replay works on the local stack. Rotation-aware follow and remote drivers remain open.</td>
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
- Uses active `ContainerClient.logRecordFile(id:)` access with a bounded local cursor for followed structured logs. Raw rotated follow still uses plugin-side merged `ContainerClient.logs(id:options:replay:)` polling until apple/container exposes a first-class follow cursor or stream.
- Stops structured follow when the `--until` deadline is reached, even when no new log records arrive.
- Buffers split structured records while the followed target is live, then flushes the final unterminated structured record when direct runtime status shows the target is no longer live.
- Cannot reconstruct capture timestamps for logs produced before the structured record store exists.

Current [`apple/container`](https://github.com/apple/container) behavior:

- Upstream exposes raw stdio and boot log file handles.
- The local `logs-integration-chris` branch exposes static `tail`, `since`, and `until` filtering through `ContainerClient.logs(id:options:replay:)`, with raw `tail` filtering performed without requiring UTF-8 decoding.
- The local `logs-integration-chris` branch accepts RFC 3339, RFC 3339 nano, Unix timestamps in seconds with optional fractional seconds, and relative durations for `container logs --since` and `--until`.
- The local `logs-integration-chris` branch stores timestamped runtime records at Docker-like line boundaries, flushes final complete records at static EOF, and exposes `ContainerClient.logRecords(id:options:replay:)` with timestamp, stream, raw bytes, and line-correct tail/since/until filtering for static replay.
- The local `logs-integration-chris` branch exposes `ContainerClient.logRecordFile(id:)` for clients that want direct structured JSONL file access.
- The local `logs-integration-chris` branch renders static `container logs --timestamps` output through structured records before rendering; upstream review still needs to confirm the contract across legacy raw logs, rotated retention, and truncation behavior.
- The local `logs-integration-chris` branch renders followed `container logs --timestamps`, `--since`, and `--until` output from the active structured record file and renders plain unfiltered `container logs --follow` from the active raw log handle.
- Does not yet have upstream-reviewed cursor, truncation, rotation, or retention semantics for long-lived rotation-aware follow clients.
- Still needs upstream review to confirm `tail`, `since`, and `until` filtering is applied to reconstructed logical log lines rather than raw storage fragments in every record source.

Missing behavior:

- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Static and followed `--timestamps`, `--since`, and `--until` work on the local integration stack, but still need upstream apple/container PR acceptance before they can be treated as released support.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Line-correct structured replay filtering works locally, but Docker parity still depends on upstream apple/container acceptance and explicit coverage for legacy raw logs, rotated retention, and truncation behavior.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> A stable record format plus active record-file follow behavior now exist locally; upstream review needs to confirm cursor, retention, and truncation behavior before plugin releases can depend on it.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Capture timestamps are unavailable for containers that only have legacy raw stdio logs.

Implementation direction:

- Split the local [`apple/container`](https://github.com/apple/container) log work into small upstream PRs from `logs-integration-chris`: retrieval-only log options, replay policy options, line-correct filtered static replay, Docker-compatible timestamp parsing, structured timestamped record storage, structured record retrieval, static rotated replay, local logging policy and rotation, and a later rotation-aware follow cursor or stream design.
- Keep the upstreamable API shape aligned with [`full-chaos/container#11`](https://github.com/full-chaos/container/pull/11) so both Compose implementations can converge on one runtime contract.
- Add golden behavior tests using RFC 3339 timestamps, Unix timestamps, relative durations, followed timestamp output, and combined `--since`/`--until` windows after the upstream API shape settles.

Completed implementation:

- Completed `2026-06-19 21:55:01 BST`: static `container-compose` timestamped logs now pass `tail`, `since`, and `until` to the direct `ContainerClient.logRecords(id:options:replay:)` API instead of reimplementing those filters locally.
- Completed `2026-06-19 21:55:01 BST`: the local apple/container branch now treats structured records as Docker-like line-framed log entries, flushes a final complete JSON record at static EOF/deadline EOF, and keeps live follow from treating a writer's incomplete JSON bytes as a record.
- Completed `2026-06-19 22:49:12 BST`: the local apple/container branch split retrieval filters from replay policy, added shared Docker-compatible timestamp parsing, and applies structured `tail`, `since`, and `until` filters after logical log-line reconstruction.
- Completed `2026-06-19 22:49:12 BST`: `container-compose` structured follow now uses the active `ContainerClient.logRecordFile(id:)` JSONL file with a bounded cursor instead of repeatedly polling full merged structured snapshots.
- Completed `2026-06-21 20:50:49 BST`: the upstreamable `logs-structured-record-storage` branch now documents and tests the active `stdio.log` raw byte format and `stdio.jsonl` JSON Lines structured record format with `timestamp`, `stream`, and base64 `data`.
- Completed `2026-06-21 21:11:04 BST`: the upstreamable `logs-structured-record-api` branch now documents and tests the active structured retrieval surfaces: `ContainerClient.logRecords(id:options:)`, `ContainerClient.logRecordFile(id:)`, `ContainerLogRecord`, XPC routes `containerLogRecords` and `containerLogRecordFile`, and `ContainerLogOptions.tail/since/until` retrieval filters.
- Completed `2026-06-21 21:16:15 BST`: PR and issue-ready design choices for the structured log slices are recorded in the container fork's [Structured Log Records PR Notes](https://github.com/stephenlclarke/container/blob/logs-structured-record-api/docs/structured-log-records-pr-notes.md), including raw versus structured storage, record boundaries, retrieval-filter ownership, XPC surfaces, Compose boundaries, and out-of-scope follow-up PRs.

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
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> Writer-level local rotation, CLI option parsing, Compose option mapping, and static rotated replay work on the local integration stack for `max-size` and `max-file`, but rotation-aware follow still needs an upstream apple/container cursor or stream design.
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
5. <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> <img alt="IMPLEMENTATION LINK" src="https://img.shields.io/badge/IMPLEMENTATION%20LINK-2563EB?style=flat-square"> <img alt="PEER TOUCHPOINT" src="https://img.shields.io/badge/PEER%20TOUCHPOINT-DB2777?style=flat-square"> <img alt="PEER OVERLAP" src="https://img.shields.io/badge/PEER%20OVERLAP-0891B2?style=flat-square"> <img alt="PEER COMPLEMENT" src="https://img.shields.io/badge/PEER%20COMPLEMENT-7C3AED?style=flat-square"> Upstream the local apple/container timestamped structured log records, direct retrieval API, static rotated replay, and a separate rotation-aware follow cursor or stream design.
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
