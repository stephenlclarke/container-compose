# Pull request: preserve archive ownership metadata during copy

<!-- markdownlint-disable MD013 -->

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Copy clients need an archive/ownership-preservation primitive to preserve UID/GID information. The existing `containerization` copy path archives directories, but streams single files as raw bytes without any ownership metadata. That blocks `apple/container` and `container-compose` from implementing Docker Compose `cp --archive` cleanly.

References:

- Docker `container cp --archive`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Docker Compose `cp --archive`: <https://docs.docker.com/reference/cli/docker/compose/cp/>

Existing upstream context:

- `apple/containerization#463` added the single-file copy agent path.
- `apple/containerization#571` added LinuxContainer directory copy support.
- `apple/containerization#614` added stat metadata support.
- `apple/containerization#636` fixed UID/GID truncation to 16 bits.
- `apple/containerization#727` added path resolution for copy-in using stat.

## Commit Tracking

- Lower runtime code commit: `d6e2a67` (`feat(copy): preserve archive ownership metadata`)
- Container API/CLI code commit: `bd7a4e8` in `stephenlclarke/container` (`feat(copy): support archive ownership mode`)
- Compose mapping code commit: `5d1c141` in `stephenlclarke/container-compose` (`feat(cp): support archive ownership mode`)

## Implementation Details

- Added `preserve_ownership`, `uid`, and `gid` fields to `CopyRequest`.
- Added `mode`, `uid`, and `gid` fields to `CopyResponse` metadata.
- Extended `Vminitd.CopyMetadata` and `Vminitd.copy(...)` with defaulted ownership parameters.
- For host-to-guest single-file copies, `LinuxContainer.copyIn` now stats the source only when ownership preservation is requested and sends the metadata to `vminitd`.
- For guest-to-host single-file copies, `vminitd` returns file metadata before the raw stream and `LinuxContainer.copyOut` applies it only when ownership preservation is requested.
- Directory copies remain on the existing tar+gzip archive path.

## Compatibility Notes

- Existing callers keep `preserveOwnership == false` by default.
- Host-side `fchown` can fail for normal user processes on macOS; the host copy path treats ownership preservation as best effort while still preserving mode where possible.
- Guest-side `fchown`/`fchmod` failures are surfaced because `vminitd` is expected to run with the privileges required to write the container root filesystem.
- This change provides the lower runtime contract only. `apple/container` still needs to expose `container copy -a, --archive`, and `container-compose` still needs to map `compose cp --archive`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused tests:

```sh
swift test --filter CopyRequestTests
```

Additional checks:

```sh
swift build
make fmt
git diff --check
```
