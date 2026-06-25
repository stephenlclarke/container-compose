<!-- markdownlint-disable MD013 -->

# feat(logs): follow locally rotated raw log files

## Template

This PR draft follows `.github/pull_request_template.md`.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This is a small, upstream-shaped slice from the current `stephenlclarke/container` `develop` fork integration lane. It builds on Chris George's log retrieval-options direction in [apple/container#1592](https://github.com/apple/container/pull/1592), the `tail` / `until` retrieval-filter follow-up in [apple/container#1764](https://github.com/apple/container/pull/1764), and the local rotation/replay handoff slices already documented in this branch. Docker-shaped timestamp parsing is now owned by `container-compose`, so [apple/container#1765](https://github.com/apple/container/pull/1765) is optional Apple CLI convenience rather than a plugin dependency.

Docker supports `container logs --follow --tail <n>` across retained local logs, and Docker Compose exposes the same workflow as `docker compose logs --follow --tail <n>`. `container-compose` needs the runtime to own this because plugin-side polling of merged retained logs is expensive and can duplicate or miss bytes around rotation. This change keeps the local storage cursor in `apple/container` and leaves Compose formatting, service selection, prefixes, and replica ordering outside this repository.

Related:

- Resolves part of [apple/container#1752](https://github.com/apple/container/issues/1752).
- Builds on [apple/container#1592](https://github.com/apple/container/pull/1592).
- Builds on [apple/container#1764](https://github.com/apple/container/pull/1764).
- Complements `docs/upstream/apple-container/ISSUE-logs-local-writer-rotation.md` / `docs/upstream/apple-container/PR-logs-local-writer-rotation.md`.
- Complements `docs/upstream/apple-container/ISSUE-logs-static-rotated-tail.md` / `docs/upstream/apple-container/PR-logs-static-rotated-tail.md`.
- Supports `container-compose logs --follow` without repeated full retained-log snapshot polling for raw stdio logs.

## Commit Tracking

- Container code commit: `f8f6623` in `stephenlclarke/container` (`feat(logs): follow rotated raw logs`).
- Container dependency commits include the local log policy/rotation replay stack, including `8daea2c` (`feat(logs): add local policy and rotation replay`).
- Lower runtime code commit: not required.
- Compose mapping is not part of this Apple PR.

## What Changed

- Adds an explicit `ContainerClient.followLogs(id:options:)` API and XPC route for followed raw stdio logs.
- Adds a service-owned `RotatingLogFollower` that starts with the requested replay window, then follows appended bytes.
- Detects rename-based active log rotation through filesystem identity changes.
- Reads any remaining bytes from the renamed active file before switching to the recreated active path.
- Supports Docker-style `tail` behavior for followed raw logs:
  - negative tail means all retained logs;
  - `tail == 0` starts with no existing output;
  - positive tail is applied to the combined retained replay before following.
- Rejects raw followed time filters so `since` and `until` stay on the structured record path where timestamps are available.
- Adds `LogFileOutput.writeStream` for API-owned streams that should be written from the current stream position without seeking to the end.
- Updates the `container logs` raw follow path to use the direct follow API when possible.
- Adds focused tests for raw stream writing, followed tail-zero behavior, and rotation handoff.

## Non-Goals

- This does not add Compose-specific log prefixes, colors, service selection, or replica ordering.
- This does not add remote logging drivers.
- This does not change the local on-disk raw or structured log format.
- This does not add rotation-aware structured/timestamped follow over `stdio.jsonl`; that remains a separate slice so raw byte streaming and structured record rendering can be reviewed independently.
- This does not change static replay filtering; retained static replay stays in the separate static rotated replay slice.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Local verification:

```bash
swift test --filter ContainerLogsTests
swift test --filter ContainerLogsCommandTests
markdownlint docs/upstream/apple-container/ISSUE-logs-rotation-aware-follow.md docs/upstream/apple-container/PR-logs-rotation-aware-follow.md
git diff --check
```

Expected focused coverage:

- followed raw logs replay the requested initial tail;
- followed raw logs treat `tail == 0` as an empty initial snapshot before following new output;
- followed raw logs continue after the active file is renamed and recreated;
- command output can write an already-following stream without seeking past the initial replay.

## Compatibility Notes

This moves `apple/container` closer to Docker and Docker Compose v2 local-development log behavior for raw stdio logs. It gives `container-compose` a direct runtime API for long-running raw follow sessions and avoids the plugin-side fallback of polling `logRecords` or static replay snapshots every few hundred milliseconds.

Released `container-compose` support still depends on the relevant `apple/container` retrieval, local rotation, and replay APIs being accepted upstream. Structured timestamped follow over rotated `stdio.jsonl` still needs a separate runtime slice before `container compose logs --timestamps --follow` can have full retained-log parity.

## Remaining Risks

- The follow stream is intentionally scoped to local raw persisted logs. Remote logging drivers and external sinks still need separate primitives.
- The follow cursor polls file identity at a small interval rather than subscribing to filesystem events. This keeps the slice small and deterministic, but maintainers may prefer a future event-backed cursor if the API server grows a shared file-watch abstraction.
- Structured/timestamped follow over rotated `stdio.jsonl` remains outstanding.
