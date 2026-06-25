# Pull request: support `container cp --archive`

<!-- markdownlint-disable MD013 -->

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Copy clients need a typed archive/ownership-preservation option to preserve source UID/GID information. `container-compose` needs this for Docker Compose `cp -a` parity, but the behavior belongs in the generic `apple/container` copy API rather than in Compose-specific orchestration.

References:

- Docker `container cp --archive`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Docker Compose `cp --archive`: <https://docs.docker.com/reference/cli/docker/compose/cp/>
- Lower runtime handoff: `docs/upstream/apple-containerization/copy/ISSUE-containerization-copy-archive-ownership.md` / `docs/upstream/apple-containerization/copy/PR-containerization-copy-archive-ownership.md`

Existing upstream context:

- `apple/container#232` requested the original `container cp` command.
- `apple/container#1190` merged the current host-container copy command.
- `apple/container#1579` and `apple/container#1580` added copy coverage and FilePath cleanup.
- `apple/container#1738`, `apple/container#1741`, `apple/container#1743`, and `apple/container#1749` cover nearby host path resolution behavior.
- `apple/container#963` and `apple/container#895` cover volume copy, which is adjacent but not a replacement for archive ownership preservation.
- `apple/container#1391` covers archiver behavior for build context entries and symlinks, but does not expose `container cp --archive`.
- `apple/container#165` and `apple/container#787` discuss adjacent UID/GID and ownership behavior for bind mounts and volumes, but not copy archive mode.
- `apple/containerization#571`, `apple/containerization#614`, `apple/containerization#636`, and `apple/containerization#727` are relevant lower-level copy/stat/UID-GID context.
- No open upstream issue or PR found for `container cp --archive` as of 2026-06-22.

## Commit Tracking

- Container code commit: `bd7a4e8` (`feat(copy): support archive ownership mode`)
- Lower runtime code commit: `d6e2a67` in `stephenlclarke/containerization` (`feat(copy): preserve archive ownership metadata`)
- Compose mapping code commit: `5d1c141` in `stephenlclarke/container-compose` (`feat(cp): support archive ownership mode`)

## Implementation Details

- Added `preserveOwnership` to the copy XPC keys.
- Added defaulted `preserveOwnership` parameters to `ContainerClient.copyIn` and `ContainerClient.copyOut`.
- Propagated the flag through `ContainersHarness`, `ContainersService`, `RuntimeClient`, and the runtime Linux plugin.
- Added `-a, --archive` to `container copy`.
- Added parser coverage for short, long, and default flag behavior.

## Compatibility Notes

- Existing API callers keep the default `preserveOwnership == false`.
- Directory copies already use archive transfer internally; this option makes the ownership intent explicit for API callers and single-file copies.
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
