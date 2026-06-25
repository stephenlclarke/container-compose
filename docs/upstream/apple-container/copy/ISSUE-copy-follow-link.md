# Feature request: expose `container cp --follow-link`

<!-- markdownlint-disable MD013 -->

## Feature or enhancement request details

Docker exposes `docker cp -L, --follow-link` to always follow symbolic links in `SRC_PATH`. Docker Compose exposes the same flag on `docker compose cp`.

`apple/container` currently supports copying files between a running container and the host, but it does not expose a user-facing or API-level option for source symlink following. This blocks Compose-compatible `cp --follow-link` support in `container-compose`.

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

## Proposed behavior

- Add `-L, --follow-link` to `container copy`.
- Add defaulted `followSymlink` options to the direct copy APIs.
- Pass the flag through the API server and runtime plugin XPC boundaries.
- Preserve existing behavior when the flag is not provided.

## Minimal example

```sh
container cp --follow-link demo:/tmp/current ./current
container cp --follow-link ./current demo:/tmp/current
```

Expected behavior:

- The source symlink is dereferenced when the flag is set.
- Existing copy calls and API users remain source-compatible.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
