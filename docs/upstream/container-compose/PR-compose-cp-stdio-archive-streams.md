# Support `compose cp -` archive streams

## Summary

This change fills the remaining Docker Compose v2 `cp` command gap:

- Supports `container compose cp - SERVICE:PATH` by reading a tar archive from stdin and copying extracted archive members into the selected service container destination.
- Supports `container compose cp SERVICE:PATH -` by staging the service container path and writing a tar archive to stdout.
- Keeps direct path copies, service-to-service copies, `--archive`, `--follow-link`, `--index`, and `--all` behavior intact.
- Marks `cp` as supported in command help and `STATUS.md`.
- Keeps the Apple runtime handoff current: a native copy-stream API would remove staging, but visible Docker Compose parity is now handled in the Compose layer.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose users commonly use `cp -` for pipeline-friendly workflows such as loading generated files into a service container or streaming a service path into another tool. `container-compose` implements both `-` operands through safe temporary staging over the existing Apple path-copy primitives.

References:

- Docker `container cp` reference: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Docker Compose `cp` reference: <https://docs.docker.com/reference/cli/docker/compose/cp/>
- Adjacent Apple PR: [apple/container#1832](https://github.com/apple/container/pull/1832)
- Required copy-out lifecycle fix: [apple/container#1927](https://github.com/apple/container/issues/1927) / [apple/containerization#799](https://github.com/apple/containerization/pull/799)
- Apple handoff note: `docs/upstream/apple-container/copy/ISSUE-copy-stdio-archive-streams.md`

## Implementation Details

- Added archive-stream helpers to the `ContainerCopying` abstraction.
- For stdin copy, the Compose layer stages stdin to a temporary archive file, extracts it with `ContainerizationArchive.ArchiveReader`, rejects unsafe archive paths, and copies each extracted top-level member through `copyIntoContainer`.
- For stdout copy, the Compose layer copies the service path to a temporary root, writes a plain tar archive with `ContainerizationArchive.ArchiveWriter`, and streams the bytes to the configured output handle without UTF-8 conversion.
- Added explicit archive input/output handles to `ComposeExecutionOptions` so tests can capture binary data deterministically.
- Updated dry-run output to show `compose-runtime cp - SERVICE:PATH` and `compose-runtime cp SERVICE:PATH -`.
- Added focused unit tests for stdin archive copy, stdout archive copy, and invalid `-` to `-` operands.
- Added Docker Compose parity coverage for round-tripping stdin and stdout archive copy workflows.

## Repository Scope

- The service selection, archive staging, and Docker Compose operand semantics stay in `stephenlclarke/container-compose`.
- `stephenlclarke/containerization` provides the copy-out lifecycle fix for [apple/container#1927](https://github.com/apple/container/issues/1927), so `compose cp SERVICE:PATH -` fails promptly when the service path is missing and leaves the container usable.
- `stephenlclarke/container` and `stephenlclarke/container-compose` pin that matched `containerization` revision.
- A future Apple API can replace the staging internals without changing the Compose CLI surface.

## Upstream Scan

- [apple/containerization#799](https://github.com/apple/containerization/pull/799) is directly relevant and represented in the local stack. The runtime cleanup was already on `stephenlclarke/containerization` `main`; this slice added the remaining regression assertion and refreshed downstream pins to `79b675d`.
- [apple/container#963](https://github.com/apple/container/pull/963) and [apple/container#895](https://github.com/apple/container/issues/895) cover volume copy, not container filesystem `cp -` archive streams, so no code was imported.
- [apple/containerization#652](https://github.com/apple/containerization/pull/652) and [apple/container#1391](https://github.com/apple/container/pull/1391) cover explicit archive entries and symlink handling for build contexts. The current stdout archive path uses existing `ArchiveWriter.archiveDirectory` behavior; no overlapping approved code was available to import.
- [apple/container#1832](https://github.com/apple/container/pull/1832) and [apple/container#1905](https://github.com/apple/container/pull/1905) are adjacent image load/save stdin/stdout fallback work, not container filesystem copy.
- A Docker Compose PR/issue scan for `cp`, stdin/stdout, tar, and archive streams found no open implementation PR to merge into this codebase.
- The approved Apple PR scan matched the current tracker in `docs/upstream/APPLE-UPSTREAM-REVIEW.md`; no newly approved copy or archive PR was available to import. The approved Docker Compose PRs were GitHub Actions dependency bumps and do not affect Compose `cp` behavior.

## Testing

Focused validation:

```sh
swift test --disable-automatic-resolution --filter 'cpStreamsStdinTarArchivesIntoServiceContainers|cpStreamsServiceContainerPathsAsStdoutTarArchives|cpRejectsUsingStdinAndStdoutArchiveStreamsTogether'
bash -n Tools/parity/check-compose-cp-stdio-archive-streams.sh
make docker-compose-cp-stdio-archive-streams-parity
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

- `cp - SERVICE:PATH` consumes stdin once and reuses the staged archive for all selected destination containers.
- `cp SERVICE:PATH -` writes binary tar bytes directly to stdout.
- The implementation uses temporary host staging because current Apple path-copy APIs do not accept caller-owned copy streams.

## Remaining Risks

- Native Apple stream-copy APIs would reduce staging and can improve very large archive performance.
- Archive extraction rejects unsafe paths before copy; future Docker Compose behavior changes around unusual tar members should be checked against the parity script.

## Checklist

- [x] Added or updated tests
- [x] Added or updated documentation
- [x] Recorded upstream issue and PR references
- [x] Kept Docker Compose policy in the Compose layer
- [x] Avoided pushing changes to Apple remotes
