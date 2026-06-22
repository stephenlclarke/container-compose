# Pull Request

## Summary

- Map Compose `cp --follow-link` to fork-backed direct copy APIs.
- Render `--follow-link` in dry-run copy commands.
- Keep `cp --archive` as the remaining copy-mode runtime gap.

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
- Runtime handoff files in the container fork: `ISSUE-copy-follow-link.md` and `PR-copy-follow-link.md`
- Lower runtime handoff files in the containerization fork: `ISSUE-containerization-copy-follow-link.md` and `PR-containerization-copy-follow-link.md`

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
- `cp --archive` remains unsupported because archive ownership preservation needs a separate runtime/API contract.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ComposeOrchestratorTests/cpFollowLinkPassesSourceSymlinkOptionToDirectCopyAPIs|ComposeOrchestratorTests/cpDryRunRendersFollowLinkFlag|ComposeOrchestratorTests/containerCopierFollowsSourceLinkOnlyWhenStagingServiceToServiceCopies|ComposeOrchestratorTests/cpRejectsArchiveOptionBeforeRuntimeCopy'
```

Additional local checks:

```sh
make check
make coverage-check
git diff --check
```

## container-compose Checks

- [x] I updated `COMPATIBILITY.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
