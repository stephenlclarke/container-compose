<!-- markdownlint-disable MD013 -->

# feat(logs): rotate local persisted log files

## Template

This PR draft follows `.github/pull_request_template.md`.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This is the runtime-writer slice for typed local log retention. Earlier local slices introduce a typed `ContainerLogConfiguration` and disabled persisted capture. This change makes the local `maxSizeInBytes` and `maxFileCount` settings affect files written by the runtime.

Docker's `json-file` and `local` logging drivers both document local file rotation through `max-size` and `max-file`. Docker Compose exposes the same intent through service `logging.driver` and `logging.options`. `container-compose` can normalize Compose service configuration and pass a typed runtime logging policy, but the runtime must own file rotation so raw and structured persisted logs stay aligned and future replay APIs can reason about retained files consistently.

Following JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), this PR should be framed as runtime retention mechanics. Docker driver aliases and option strings stay in `container-compose`.

Related:

- Supports part of [apple/container#1752](https://github.com/apple/container/issues/1752).
- Builds on Chris George's retrieval-options direction in [apple/container#1592](https://github.com/apple/container/pull/1592).
- Stacks after the typed local policy model handoff in `docs/upstream/apple-container/ISSUE-logs-local-policy-model.md` / `docs/upstream/apple-container/PR-logs-local-policy-model.md`.
- Stacks after the disabled local capture handoff in `docs/upstream/apple-container/ISSUE-logs-disabled-local-capture.md` / `docs/upstream/apple-container/PR-logs-disabled-local-capture.md`.
- Stacks after Compose can translate local logging driver/options into `ContainerLogConfiguration`.
- Pairs with the static rotated replay handoff in `docs/upstream/apple-container/ISSUE-logs-static-rotated-tail.md` / `docs/upstream/apple-container/PR-logs-static-rotated-tail.md`.

## What Changed

- Opens local log writers from file URLs so active raw and structured log sizes can be measured.
- Applies local rotation before a write would exceed `ContainerLogConfiguration.maxSizeInBytes`.
- Rotates `stdio.log` and `stdio.jsonl` together to preserve raw/structured sidecar alignment.
- Retains at most `ContainerLogConfiguration.maxFileCount` files, including the active file.
- Treats `maxFileCount == 1` as active-file-only retention.
- Reopens fresh active raw and structured log files after rotation.
- Wires `RuntimeService.containerLogWriter` to pass the configured local retention policy to the writer.
- Adds focused writer and runtime-service tests for retained rotation, active-only retention, and existing active file size accounting.

## Non-Goals

- This does not add or change Compose-specific log prefixes, colors, service selection, replica fan-out, or validation wording.
- This does not add remote logging drivers or external log sinks.
- This does not add compressed rotated files.
- This does not implement a rotation-aware structured record follow cursor or stream.
- This does not change static replay filtering; retained replay stays in the separate static rotated replay slice.
- This does not implement Docker's exact on-disk `json-file` or `local` binary/storage format. `apple/container` continues to use raw `stdio.log` plus structured `stdio.jsonl` records as its local runtime format.

## Intended Review Delta

The code-bearing local integration commit for this slice is:

- `06862b7 feat(logs): rotate local log files`

The handoff files are:

- `ISSUE-logs-local-writer-rotation.md`
- `PR-logs-local-writer-rotation.md`

This slice should be reviewed after the logging policy model settles, because it consumes `ContainerLogConfiguration.maxSizeInBytes` and `ContainerLogConfiguration.maxFileCount`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Local verification:

```bash
swift test --filter ContainerLogFileWriterTests
swift test --filter ComposeOrchestratorTests
markdownlint docs/upstream/apple-container/ISSUE-logs-local-writer-rotation.md docs/upstream/apple-container/PR-logs-local-writer-rotation.md
git diff --check
```

Expected focused coverage:

- raw and structured files rotate together;
- retention keeps the active file plus at most `max-file - 1` rotated files;
- `max-file == 1` keeps only active raw and structured files;
- runtime writer construction forwards local rotation policy from `ContainerLogConfiguration`;
- reopened active files seed size counters before applying the next write.

## Compatibility Notes

This moves `apple/container` closer to Docker Compose v2 local-development behavior for Compose services that configure local logging with `json-file`, `local`, `max-size`, and `max-file`. It is intentionally limited to local persisted capture. Remote drivers, metadata options, delivery modes, compression, and Compose presentation stay unsupported until separate runtime primitives exist.

## Remaining Risks

- The local format intentionally differs from Docker Engine's on-disk driver formats, so parity should be measured at the CLI/API behavior boundary rather than by file layout.
- A rotation-aware structured follow cursor or stream is still needed before timestamped `container compose logs --follow` can avoid plugin-side polling.
- Static and structured rotated replay depend on the separate replay/API slices being accepted upstream.
