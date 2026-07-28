# Support `compose cp -` archive streams

## Summary

This change closes the remaining Docker Compose v2 `cp` archive-fidelity gap:

- Streams `container compose cp - SERVICE:PATH` archives directly into the selected service container.
- Streams `container compose cp SERVICE:PATH -` archives directly from the service container.
- Pipes service-to-service copies between the native archive APIs without unpacking data on the host.
- Keeps direct path copies, service-to-service copies, `--archive`, `--follow-link`, `--index`, and `--all` behavior intact.
- Preserves ownership, mode, timestamps, hard links, symlinks, sparse allocation, long paths, and large files through the matched runtime stack.
- Records Docker Compose and container-compose timings for each parity operation.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose users commonly use `cp -` for pipeline-friendly workflows such as loading generated files into a service container or streaming a service path into another tool. The earlier host-staged implementation preserved content but lost metadata at extraction and re-archiving boundaries. The matched Stephen-owned runtime stack now exposes caller-owned archive streams, allowing Compose to retain Docker-compatible archive semantics without host extraction.

References:

- Docker `container cp` reference: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Docker Compose `cp` reference: <https://docs.docker.com/reference/cli/docker/compose/cp/>
- Adjacent Apple PR: [apple/container#1832](https://github.com/apple/container/pull/1832)
- Required copy-out lifecycle fix: [apple/container#1927](https://github.com/apple/container/issues/1927) / [apple/containerization#799](https://github.com/apple/containerization/pull/799)
- Apple handoff note: `docs/upstream/apple-container/copy/ISSUE-copy-stdio-archive-streams.md`

## Implementation Details

- Added the optional `ComposeRuntimeArchiveCopying` capability without breaking alternate path-only runtime providers.
- For one stdin destination, Compose passes the caller's archive handle directly to the runtime. For `--all`, it stages the raw archive bytes once and reopens the archive for each destination; it never extracts the archive on the host.
- For stdout, Compose passes the caller's output handle directly to the runtime and preserves trailing `/.` contents semantics.
- For service-to-service copies, `ContainerClientCopier` concurrently connects native copy-out and copy-in calls through a Unix socket pair. Either-side failure closes both handles so the sibling cannot remain blocked.
- The runtime-neutral fallback remains available for alternate providers and now honours requested ownership when extracting.
- Added explicit archive input/output handles to `ComposeExecutionOptions` so tests can capture binary data deterministically.
- Updated dry-run output to show `compose-runtime cp - SERVICE:PATH` and `compose-runtime cp SERVICE:PATH -`.
- Added focused unit tests for exact archive-byte forwarding, `--all` replay, trailing-dot semantics, direct service-to-service streaming, and producer/consumer failure unblocking.
- Expanded the Docker Compose parity fixture to require ownership, mode, timestamp, symlink, hard-link, sparse allocation, long-path, and large-file fidelity.
- Added bounded, machine-readable timing capture. A slower result remains evidence rather than a functional failure unless it both exceeds the configurable ratio and practical absolute-delay thresholds.

## Repository Scope

- Service selection, `--all` replay, trailing-dot handling, and Docker Compose operand semantics stay in `stephenlclarke/container-compose`.
- `stephenlclarke/containerization` `52386838456a431d24bed6c38a9e84fb0ad28997` owns archive production, extraction, metadata fidelity, path safety, cancellation, sparse files, and hard links.
- `stephenlclarke/container` `f5e25b12ed074e7e5fb09933d86a27652034f3e5` forwards caller-owned archive handles through the XPC and runtime service boundaries.
- `Package.swift`, `Package.resolved`, and `Tools/release/stack-refs.json` pin the same reviewed revisions.

## Upstream Scan

- [apple/containerization#799](https://github.com/apple/containerization/pull/799) is directly relevant and represented in the local stack. Its copy-out failure cleanup remains required so producer errors terminate metadata and listener streams promptly.
- [apple/container#963](https://github.com/apple/container/pull/963) and [apple/container#895](https://github.com/apple/container/issues/895) cover volume copy, not container filesystem `cp -` archive streams, so no code was imported.
- [apple/containerization#652](https://github.com/apple/containerization/pull/652) and [apple/container#1391](https://github.com/apple/container/pull/1391) cover explicit archive entries and symlink handling for build contexts. The direct copy implementation reuses the repository's archive package rather than introducing a Compose-specific archive codec.
- [apple/container#1832](https://github.com/apple/container/pull/1832) and [apple/container#1905](https://github.com/apple/container/pull/1905) are adjacent image load/save stdin/stdout fallback work, not container filesystem copy.
- [apple/containerization#812](https://github.com/apple/containerization/pull/812) and [apple/container#1947](https://github.com/apple/container/pull/1947) are third-party direct-stream proposals. The supported fork implementation was reviewed independently and strengthened for caller-handle ownership, cancellation, backpressure, path safety, metadata, sparse files, hard links, and trailing-dot semantics.
- A Docker Compose PR/issue scan for `cp`, stdin/stdout, tar, and archive streams found no open implementation PR to merge into this codebase.
- The approved Apple PR scan matched the current tracker in `docs/upstream/APPLE-UPSTREAM-REVIEW.md`; no newly approved copy or archive PR was available to import. The approved Docker Compose PRs were GitHub Actions dependency bumps and do not affect Compose `cp` behavior.

## Testing

Focused validation:

```sh
swift test --disable-automatic-resolution --filter 'cpStreamsStdinTarArchivesIntoServiceContainers|cpAllReplaysStdinArchiveBytesIntoEverySelectedContainer|cpStreamsServiceContainerPathsAsStdoutTarArchives|cpStdoutPreservesTrailingDotContentsSemantics|containerCopierStreamsServiceToServiceCopiesDirectly|containerCopierUnblocksArchiveInputWhenArchiveOutputFails|containerCopierUnblocksArchiveOutputWhenArchiveInputFails'
bash -n Tools/parity/check-compose-cp-stdio-archive-streams.sh
PARITY_TIMING_OUTPUT=/tmp/compose-cp-timings.tsv make docker-compose-cp-stdio-archive-streams-parity
```

Before release promotion:

```sh
make check
make test
make coverage-check
make docker-compose-parity
git diff --check
npx --yes markdownlint-cli2 $(git ls-files '*.md')
```

## Compatibility Notes

- `cp - SERVICE:PATH` consumes stdin directly for one destination. `--all` stages raw archive bytes once and replays them without extraction.
- `cp SERVICE:PATH -` writes binary tar bytes directly to stdout.
- Service-to-service copies use a bounded-lifecycle Unix socket pair between the runtime archive APIs.
- Alternate path-only runtime providers continue to use the safe staging fallback.
- The direct APIs are currently supplied by exact Stephen-owned Container and Containerization revisions rather than stock Apple releases.

## Remaining Risks

- The archive APIs remain fork-only until Apple accepts an equivalent reviewed implementation.
- `--all` deliberately uses a temporary raw archive file because one input stream cannot be consumed by several destination containers.
- Future Docker Compose behavior changes around unusual tar members should be checked against the parity script.

## Checklist

- [x] Added or updated tests
- [x] Added or updated documentation
- [x] Recorded upstream issue and PR references
- [x] Kept Docker Compose policy in the Compose layer
- [x] Avoided pushing changes to Apple remotes
