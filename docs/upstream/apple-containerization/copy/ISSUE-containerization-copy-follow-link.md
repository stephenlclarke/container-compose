# Feature request: follow source symlinks during container copy-out

<!-- markdownlint-disable MD013 -->

## Feature or enhancement request details

Docker exposes `docker cp -L, --follow-link` to copy the target of `SRC_PATH` when that source path is a symbolic link. `apple/container` and `container-compose` need the same lower-runtime primitive when the source path is inside a Linux container root filesystem.

The current copy control plane has `CopyRequest.is_archive`, but it does not let callers ask the guest copy agent to dereference the source symlink before deciding whether it is copying a single file or archiving a directory.

References:

- Docker `container cp --follow-link`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Docker Compose `cp --follow-link`: <https://docs.docker.com/reference/cli/docker/compose/cp/>

Existing upstream context:

- `apple/containerization#463` added the single-file copy agent path.
- `apple/containerization#571` added LinuxContainer directory copy support.
- `apple/containerization#614` added the stat RPC used by later copy path-resolution work.
- `apple/containerization#727` added path resolution for copy-in using stat.

## Proposed behavior

- Add an opt-in `follow_symlink` field to the copy request.
- Keep the default copy behavior unchanged.
- Apply the flag only to the requested source path for `COPY_OUT`.
- Resolve absolute symlink targets under the mounted container rootfs instead of the init VM filesystem.

## Minimal example

```sh
container cp --follow-link demo:/tmp/current ./current
```

Expected behavior:

- If `/tmp/current` is a symlink inside the container, the copied output contains the target content.
- If the option is omitted, existing copy behavior remains unchanged.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
