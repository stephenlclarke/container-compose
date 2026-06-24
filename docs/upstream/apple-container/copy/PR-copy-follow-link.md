# Pull request: support `container cp --follow-link`

<!-- markdownlint-disable MD013 -->

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Copy clients need a typed follow-link option to dereference the source path when it is a symlink. `container-compose` needs this for Docker Compose `cp -L` parity, but the behavior belongs in the generic `apple/container` copy API rather than in Compose-specific orchestration.

References:

- Docker `container cp --follow-link`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Docker Compose `cp --follow-link`: <https://docs.docker.com/reference/cli/docker/compose/cp/>
- Lower runtime handoff: `docs/upstream/apple-containerization/copy/ISSUE-containerization-copy-follow-link.md` / `docs/upstream/apple-containerization/copy/PR-containerization-copy-follow-link.md`

Existing upstream context:

- `apple/container#232` requested the original `container cp` command.
- `apple/container#1190` merged the current host-container copy command.
- `apple/container#1579` and `apple/container#1580` added copy coverage and FilePath cleanup.
- `apple/container#1738`, `apple/container#1741`, `apple/container#1743`, and `apple/container#1749` cover nearby host path resolution behavior.
- `apple/container#963` and `apple/container#895` cover volume copy, which is adjacent but not a replacement for source symlink dereference.
- No open upstream issue or PR found for `container cp --follow-link` as of 2026-06-22.

## Commit Tracking

- Container code commit: `386622c` (`feat(copy): expose follow-link option`)
- Lower runtime code commit: `2747b9e` in `stephenlclarke/containerization` (`feat(copy): add follow-link runtime option`)
- Compose mapping code commit: `1542880` in `stephenlclarke/container-compose` (`feat(cp): support follow-link copy option`)

## Implementation Details

- Added `followSymlink` to the copy XPC keys.
- Added defaulted `followSymlink` parameters to `ContainerClient.copyIn` and `ContainerClient.copyOut`.
- Propagated the flag through `ContainersHarness`, `ContainersService`, `RuntimeClient`, and the runtime Linux plugin.
- Added `-L, --follow-link` to `container copy`.
- Added parser coverage for short, long, and default flag behavior.

## Compatibility Notes

- Existing API callers keep the default `followSymlink == false`.
- This does not implement `cp --archive`; UID/GID preservation remains a separate copy-mode change.
- This does not add Compose-specific service lookup or fan-out behavior to `apple/container`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused tests:

```sh
swift test --filter ContainerCopyCommandTests
```

Additional checks:

```sh
swift build --product container
swift build --product container-apiserver
swift build --product container-runtime-linux
make fmt
git diff --check
```
