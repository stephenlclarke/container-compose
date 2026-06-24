<!-- markdownlint-disable MD013 -->

# feat(logs): follow locally rotated structured log records

## Template

This PR draft follows `.github/pull_request_template.md`.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This is a small, upstream-shaped slice from the local `logs-integration-chris` proving branch. It builds on Chris George's log retrieval-options direction in [apple/container#1592](https://github.com/apple/container/pull/1592), the `tail` / `until` retrieval-filter follow-up in [apple/container#1764](https://github.com/apple/container/pull/1764), and the local raw rotation/replay slices already documented in this branch. Docker-shaped timestamp parsing is now owned by `container-compose`, so [apple/container#1765](https://github.com/apple/container/pull/1765) is optional Apple CLI convenience rather than a plugin dependency.

Docker supports `container logs --follow --timestamps`, `--since`, `--until`, and `--tail`. Docker Compose exposes the same behavior for service logs through `docker compose logs`. `container-compose` needs the runtime to own structured followed replay because plugin-side polling of merged retained snapshots is expensive and can duplicate or miss records around rotation.

This change keeps the storage cursor and line-level filtering in `apple/container`. Compose formatting, service selection, prefixes, colors, project fan-out, and replica ordering remain outside this repository.

Related:

- Resolves part of [apple/container#1752](https://github.com/apple/container/issues/1752).
- Builds on [apple/container#1592](https://github.com/apple/container/pull/1592).
- Builds on [apple/container#1764](https://github.com/apple/container/pull/1764).
- Complements `docs/upstream/apple-container/ISSUE-logs-rotation-aware-follow.md` / `docs/upstream/apple-container/PR-logs-rotation-aware-follow.md`.
- Complements `docs/upstream/apple-container/ISSUE-logs-static-rotated-tail.md` / `docs/upstream/apple-container/PR-logs-static-rotated-tail.md`.
- Supports `container-compose logs --follow --timestamps`, followed time filters, and followed structured service logs without repeated full retained-log snapshot polling.

## Commit Tracking

- Container code commit: `43add25` in `stephenlclarke/container` (`feat(logs): follow structured record rotations`).
- Container dependency commits include `b598ead` (`feat(logs): add structured log retrieval stack`) and the local raw rotation/replay stack.
- Lower runtime code commit: not required.
- Compose mapping is not part of this Apple PR.

## What Changed

- Adds an explicit `ContainerClient.followLogRecords(id:options:)` API and XPC route for followed structured log records.
- Adds a service-owned structured follower that uses the existing local rotation cursor.
- Replays retained rotated `stdio.jsonl` files and the active prefix that existed before following began.
- Rebuilds stored runtime chunks into logical log lines before applying retrieval filters.
- Applies Docker-style followed structured filters:
  - negative tail means all retained records;
  - `tail == 0` starts with no existing output;
  - positive tail is applied after logical line reconstruction;
  - `since` and `until` are applied to logical line timestamps.
- Ignores an open JSONL fragment at a `tail == 0` snapshot boundary so an old in-progress record is not emitted later.
- Carries partial log-line state across active-file rotation.
- Flushes a final partial logical line when the container stops.
- Updates `container logs --follow` with `--timestamps`, `--since`, or `--until` to consume the runtime-owned structured follow stream.
- Adds focused tests for structured follow replay, `tail == 0`, open initial fragments, rotation, partial lines, stop flush, and initial time/tail filtering.

## Non-Goals

- This does not add Compose-specific log prefixes, colors, service selection, or replica ordering.
- This does not add remote logging drivers.
- This does not change the local on-disk raw or structured log format.
- This does not add external filesystem event watching; the cursor continues to poll local file identity like the raw follow slice.
- This does not add any `container-compose` logic to `apple/container`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Local verification:

```bash
swift test --filter ContainerLogsTests
swift test --filter ContainerLogsCommandTests
markdownlint docs/upstream/apple-container/ISSUE-logs-structured-rotation-aware-follow.md docs/upstream/apple-container/PR-logs-structured-rotation-aware-follow.md
git diff --check
```

Expected focused coverage:

- followed structured records replay the requested initial tail;
- followed structured records treat `tail == 0` as an empty initial snapshot before following new output;
- followed structured records skip an open initial JSONL fragment for `tail == 0`;
- followed structured records continue after the active file is renamed and recreated;
- followed structured records complete a partial logical line across rotation;
- followed structured records flush a final unterminated logical line when the container stops;
- followed structured records apply initial `since`, `until`, and `tail` at logical-line boundaries.

## Compatibility Notes

This moves `apple/container` closer to Docker and Docker Compose v2 local-development log behavior for timestamped and time-filtered followed logs. It gives `container-compose` a direct runtime API for long-running structured follow sessions and avoids the plugin-side fallback of polling `logRecords` or static replay snapshots every few hundred milliseconds.

Released `container-compose` support still depends on the relevant `apple/container` retrieval, local rotation, and replay APIs being accepted upstream. Until then, full structured follow parity remains available only when the plugin is built against a fork containing these local runtime slices.

## Remaining Risks

- The follow cursor polls file identity at a small interval rather than subscribing to filesystem events. This matches the raw follow slice and keeps the change deterministic, but maintainers may prefer a future shared file-watch abstraction.
- Remote logging drivers and external sinks still need separate primitives.
- This API streams line-reconstructed `ContainerLogRecord` values rather than byte-for-byte stored JSONL chunks. That is intentional for Docker line-level filtering, but it should be called out during review because `logRecordFile(id:)` remains the lower-level raw active file handle.
