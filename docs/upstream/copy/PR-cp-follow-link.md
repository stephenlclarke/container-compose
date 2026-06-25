# Pull request: support `container compose cp --follow-link`

<!-- markdownlint-disable MD013 -->

## Summary

- Map Compose `cp --follow-link` to fork-backed direct copy APIs.
- Render `--follow-link` in dry-run copy commands.
- Preserve default copy behavior when the flag is not provided.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose supports `docker compose cp -L, --follow-link`, which follows symbolic links in `SRC_PATH`. The plugin previously rejected this option because released upstream `apple/container` did not expose a copy follow-link option. The local integration branches now carry a defaulted `followSymlink` option through `containerization` and `apple/container`, so Compose can support the flag without shelling out or adding Compose-specific behavior to the runtime.

References:

- Docker Compose `cp --follow-link`: <https://docs.docker.com/reference/cli/docker/compose/cp/>
- Docker `container cp --follow-link`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Runtime handoff files in the container fork: `docs/upstream/copy/ISSUE-copy-follow-link.md` and `docs/upstream/copy/PR-copy-follow-link.md`
- Lower runtime handoff files in the containerization fork: `docs/upstream/copy/ISSUE-containerization-copy-follow-link.md` and `docs/upstream/copy/PR-containerization-copy-follow-link.md`

Existing upstream context:

- `apple/container#232` requested the original `container cp` command.
- `apple/container#1190` merged the current host-container copy command.
- `apple/container#1579` and `apple/container#1580` added copy coverage and FilePath cleanup.
- `apple/container#1738`, `apple/container#1741`, `apple/container#1743`, and `apple/container#1749` cover nearby host path resolution behavior.
- `apple/container#963` and `apple/container#895` cover volume copy, which is adjacent but not a replacement for source symlink dereference.
- No open upstream issue or PR found for `container cp --follow-link` or `container compose cp --follow-link` as of 2026-06-22.

## Commit Tracking

- Lower runtime code commit: `2747b9e` in `stephenlclarke/containerization` (`feat(copy): add follow-link runtime option`)
- Container code commit: `386622c` in `stephenlclarke/container` (`feat(copy): expose follow-link option`)
- Compose code commit: `1542880` (`feat(cp): support follow-link copy option`)

## Implementation Details

- Added `ContainerCopyTransferOptions` for direct copy adapter options.
- Passed `ComposeCopyOptions.followLink` to copy-in, copy-out, and service-to-service staging.
- Scoped service-to-service `--follow-link` to the source copy-out leg; the staged host file is copied into the destination without reapplying source-link semantics.
- Updated dry-run copy command rendering to include `--follow-link`.
- Removed the previous `cp --follow-link` unsupported validation path.
- Added focused orchestrator and adapter tests.

## Docker Compose Compatibility Notes

- Supported on fork-backed integration branches pinned to `stephenlclarke/container` and `stephenlclarke/containerization`.
- Branches pinned to released upstream `apple/container` must keep treating this as runtime-gated until the copy follow-link API is accepted upstream.
- `cp --archive` is handled by the separate archive ownership change.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ComposeOrchestratorTests/cpFollowLinkPassesSourceSymlinkOptionToDirectCopyAPIs|ComposeOrchestratorTests/cpDryRunRendersFollowLinkFlag|ComposeOrchestratorTests/containerCopierFollowsSourceLinkOnlyWhenStagingServiceToServiceCopies'
```

Additional local checks:

```sh
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
