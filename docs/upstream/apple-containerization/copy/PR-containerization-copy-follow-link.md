# Pull request: add copy follow-link runtime option

<!-- markdownlint-disable MD013 -->

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Copy clients need a runtime primitive for follow-link behavior when the source path lives inside the container root filesystem. The current copy protobuf can tell the guest whether incoming data is an archive, but cannot tell the guest to dereference the outgoing source path before choosing file versus directory transfer.

References:

- Docker `container cp --follow-link`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Docker Compose `cp --follow-link`: <https://docs.docker.com/reference/cli/docker/compose/cp/>

Existing upstream context:

- `apple/containerization#463` added the single-file copy agent path.
- `apple/containerization#571` added LinuxContainer directory copy support.
- `apple/containerization#614` added the stat RPC used by later copy path-resolution work.
- `apple/containerization#727` added path resolution for copy-in using stat.

## Commit Tracking

- Lower runtime code commit: `2747b9e` (`feat(copy): add follow-link runtime option`)
- Container API/CLI code commit: `386622c` in `stephenlclarke/container` (`feat(copy): expose follow-link option`)
- Compose mapping code commit: `1542880` in `stephenlclarke/container-compose` (`feat(cp): support follow-link copy option`)

## Implementation Details

- Added `CopyRequest.follow_symlink`.
- Regenerated the Swift protobuf bindings.
- Added a defaulted `followSymlink` parameter to `Vminitd.copy`.
- Added defaulted `followSymlink` parameters to `LinuxContainer.copyIn` and `LinuxContainer.copyOut`.
- For `COPY_OUT`, the guest agent follows only the final source symlink and translates absolute symlink targets back under `/run/container/<id>/rootfs`.
- For `COPY_IN`, the host-side transfer source can be resolved before streaming while preserving the original source basename for destination-directory copies.

## Compatibility Notes

- Existing callers keep `followSymlink == false`.
- This does not implement Docker `cp --archive`; ownership preservation remains a separate copy-mode discussion.
- This does not recursively dereference symlinks inside a copied directory tree.

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
make fmt
git diff --check
```
