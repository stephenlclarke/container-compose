<!-- markdownlint-disable MD013 -->

# feat(logs): bound static rotated tail replay

## Template

This PR draft follows `.github/pull_request_template.md`.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This Apple-shaped runtime slice builds on Chris George's log retrieval-options direction in [apple/container#1592](https://github.com/apple/container/pull/1592) and the `tail` / `until` retrieval-filter follow-up in [apple/container#1764](https://github.com/apple/container/pull/1764). Docker-shaped timestamp parsing is owned by `container-compose`, so [apple/container#1765](https://github.com/apple/container/pull/1765) is optional Apple CLI convenience rather than a plugin dependency.

Docker Compose documents `docker compose logs --tail` as a per-container line count, and Compose services can configure local retained logs through `logging.options.max-size` and `logging.options.max-file`. External orchestrators such as `container-compose` need a runtime-owned way to request static retained log replay without polling or reading complete retained log history in the plugin.

This change keeps that behavior inside the runtime boundary. The plugin can ask for `ContainerLogReplayOptions(includeRotated: true)` plus `ContainerLogOptions(tail:)`; `apple/container` owns active-plus-rotated file ordering and the bounded tail scan. Compose-specific presentation remains outside this repository.

Related:

- Resolves part of [apple/container#1752](https://github.com/apple/container/issues/1752).
- Builds on [apple/container#1592](https://github.com/apple/container/pull/1592).
- Builds on [apple/container#1764](https://github.com/apple/container/pull/1764).
- Supports `container-compose` static `logs --tail` replay without whole-history reads.

## Commit Tracking

- Container code commit: `86a9bda` in `stephenlclarke/container` (`feat(logs): bound static rotated tail replay`).
- Container dependency commits include the local log policy/rotation replay stack, including `8daea2c` (`feat(logs): add local policy and rotation replay`).
- Lower runtime code commit: not required.
- Compose mapping is not part of this Apple PR.

## What Changed

- Adds a bounded reverse scan for static tail-only raw log replay.
- Applies static positive `tail` across active plus rotated log files after constructing the chronological stream.
- Preserves Docker-style negative tail as "all retained logs".
- Preserves `tail == 0` as empty output.
- Rebuilds logical lines that are split across rotation boundaries before final tail filtering.
- Leaves time-filtered replay on the existing full read path, because `since` and `until` still require full logical-line reconstruction in this slice.
- Keeps followed structured logs on the active record file path; rotation-aware structured follow cursor semantics remain a separate runtime design.

## Non-Goals

- This does not add Compose-specific log prefixes, colors, service selection, or replica ordering.
- This does not add remote logging drivers.
- This does not add a rotation-aware structured record follow cursor.
- This does not change the accepted shape of `ContainerLogOptions` from the retrieval-filter work.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Local verification:

```bash
swift test --filter ContainerLogsTests
swift test --filter ContainerLogsCommandTests
PATH="$PWD/.local/bin:$PATH" make fmt
git diff --check
```

Result:

- `ContainerLogsTests`: 22 passing tests.
- `ContainerLogsCommandTests`: 37 passing tests.
- Formatting and whitespace checks passed locally.

New or relevant coverage:

- Static rotated replay includes rotated files in chronological order.
- Static rotated replay applies `tail` after combining retained files.
- Bounded tail replay rebuilds a logical line split across rotated files.
- Followed structured output with negative tail replays existing records instead of trapping or dropping output.

## Compatibility Notes

This moves `container-compose` closer to Docker Compose v2 static log behavior for local-development workflows. The plugin already requests direct runtime replay through `ContainerClient.logs(id:options:replay:)`; this runtime slice makes that request efficient and line-correct for static raw retained logs. Released `container-compose` support still depends on the relevant `apple/container` retrieval and replay APIs being accepted upstream.

## Remaining Risks

- Rotation-aware structured follow still needs a separate cursor or streaming API so long-running timestamped `logs --follow` clients do not poll merged snapshots.
- Time-windowed rotated replay still uses the full-read path in this slice.
- Structured rotated replay should remain a separate PR after structured log records and the structured retrieval API are accepted.
