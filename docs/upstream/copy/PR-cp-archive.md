# Pull request: support `container compose cp --archive`

<!-- markdownlint-disable MD013 -->

## Summary

- Map Compose `cp --archive` to fork-backed direct copy APIs.
- Render `--archive` in dry-run copy commands.
- Request archive ownership preservation on both service-to-service staging legs.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose supports `docker compose cp -a, --archive`, which preserves source UID/GID information where possible. The plugin previously rejected this option because released upstream `apple/container` did not expose copy archive controls. The local integration branches now carry a defaulted `preserveOwnership` option through `containerization` and `apple/container`, so Compose can support the flag without shelling out or adding Compose-specific behavior to the runtime.

References:

- Docker Compose `cp --archive`: <https://docs.docker.com/reference/cli/docker/compose/cp/>
- Docker `container cp --archive`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Runtime handoff files: `docs/upstream/apple-container/copy/ISSUE-copy-archive.md` and `docs/upstream/apple-container/copy/PR-copy-archive.md`
- Lower runtime handoff files: `docs/upstream/apple-containerization/copy/ISSUE-containerization-copy-archive-ownership.md` and `docs/upstream/apple-containerization/copy/PR-containerization-copy-archive-ownership.md`

Existing upstream context:

- `apple/container#232` requested the original `container cp` command.
- `apple/container#1190` merged the current host-container copy command.
- `apple/container#1579` and `apple/container#1580` added copy coverage and FilePath cleanup.
- `apple/container#1738`, `apple/container#1741`, `apple/container#1743`, and `apple/container#1749` cover nearby host path resolution behavior.
- `apple/container#963` and `apple/container#895` cover volume copy, which is adjacent but not a replacement for archive ownership preservation.
- `apple/container#1391` covers archiver behavior for build context entries and symlinks, but does not expose `container cp --archive`.
- `apple/container#165` and `apple/container#787` discuss adjacent UID/GID and ownership behavior for bind mounts and volumes, but not copy archive mode.
- `apple/containerization#571`, `apple/containerization#614`, `apple/containerization#636`, and `apple/containerization#727` are relevant lower-level copy/stat/UID-GID context.
- No open upstream issue or PR found for `container cp --archive` or `container compose cp --archive` as of 2026-06-22.

## Commit Tracking

- Lower runtime code commit: `d6e2a67` in `stephenlclarke/containerization` (`feat(copy): preserve archive ownership metadata`)
- Container code commit: `bd7a4e8` in `stephenlclarke/container` (`feat(copy): support archive ownership mode`)
- Compose code commit: `5d1c141` (`feat(cp): support archive ownership mode`)

## Implementation Details

- Added `ContainerCopyTransferOptions.preserveOwnership`.
- Passed `ComposeCopyOptions.archive` to copy-in, copy-out, and service-to-service staging.
- Requested ownership preservation on both service-to-service staging legs while keeping `--follow-link` source-only.
- Updated dry-run copy command rendering to include `--archive`.
- Removed the previous `cp --archive` unsupported validation path.
- Added focused orchestrator and adapter tests.

## Docker Compose Compatibility Notes

- Supported on fork-backed integration branches pinned to `stephenlclarke/container` and `stephenlclarke/containerization`.
- Branches pinned to released upstream `apple/container` must keep treating this as runtime-gated until the copy archive API is accepted upstream.
- Service-to-service copy is a `container-compose` extension implemented through host staging; archive mode requests preservation on both staging legs, but host permissions can limit UID/GID preservation when writing the staged file.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ComposeOrchestratorTests/cpArchivePassesOwnershipPreservationOptionToDirectCopyAPIs|ComposeOrchestratorTests/cpDryRunRendersArchiveFlag|ComposeOrchestratorTests/containerCopierRequestsOwnershipPreservationWhenStagingServiceToServiceCopies'
```

Additional local checks:

```sh
swift build --product compose
make check
make coverage-check
git diff --check
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
