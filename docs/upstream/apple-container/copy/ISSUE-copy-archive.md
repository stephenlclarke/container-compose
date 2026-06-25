# Feature request: expose `container cp --archive`

<!-- markdownlint-disable MD013 -->

## Feature or enhancement request details

Docker exposes `docker cp -a, --archive` to copy files while preserving UID/GID information where possible. Docker Compose exposes the same flag on `docker compose cp`.

`apple/container` currently supports copying files between a running container and the host, but the user-facing copy command and direct copy APIs do not expose an archive mode. That blocks Docker Compose-compatible `cp --archive` support in `container-compose`.

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

## Proposed behavior

- Add `-a, --archive` to `container copy`.
- Add a defaulted `preserveOwnership` option to the direct copy APIs.
- Pass the flag through the API server and runtime plugin XPC boundaries.
- Preserve existing behavior when the flag is not provided.

## Minimal example

```sh
container cp --archive demo:/etc/app/config.json ./config.json
container cp --archive ./config.json demo:/etc/app/config.json
```

Expected behavior:

- The copy operation preserves UID/GID information where the underlying runtime and host permissions allow it.
- Existing copy calls and API users remain source-compatible.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
