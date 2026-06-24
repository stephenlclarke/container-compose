# Feature request: support `container compose cp --follow-link`

<!-- markdownlint-disable MD013 -->

## Feature or enhancement request details

Docker Compose exposes `docker compose cp -L, --follow-link` to copy the target of a symbolic link in `SRC_PATH`. `container-compose` previously rejected this option because released upstream `apple/container` did not expose copy follow-link controls.

The local integration stack now carries fork-backed `followSymlink` support through `containerization` and `apple/container`, so the plugin can map the Compose flag through its direct copy adapter.

References:

- Docker Compose `cp --follow-link`: <https://docs.docker.com/reference/cli/docker/compose/cp/>
- Docker `container cp --follow-link`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Runtime handoff files: `docs/upstream/apple-container/copy/ISSUE-copy-follow-link.md` and `docs/upstream/apple-container/copy/PR-copy-follow-link.md`
- Lower runtime handoff files: `docs/upstream/apple-containerization/copy/ISSUE-containerization-copy-follow-link.md` and `docs/upstream/apple-containerization/copy/PR-containerization-copy-follow-link.md`

Existing upstream context:

- `apple/container#232` requested the original `container cp` command.
- `apple/container#1190` merged the current host-container copy command.
- `apple/container#1579` and `apple/container#1580` added copy coverage and FilePath cleanup.
- `apple/container#1738`, `apple/container#1741`, `apple/container#1743`, and `apple/container#1749` cover nearby host path resolution behavior.
- `apple/container#963` and `apple/container#895` cover volume copy, which is adjacent but not a replacement for source symlink dereference.
- No open upstream issue or PR found for `container cp --follow-link` or `container compose cp --follow-link` as of 2026-06-22.

## Proposed behavior

- Accept `container compose cp --follow-link` / `-L`.
- Pass the option through direct `ContainerClient.copyIn` / `copyOut` calls.
- Apply the option to service-to-service copies only for the source container copy-out leg.
- Keep default copy behavior unchanged when the flag is not provided.

## Minimal example

```sh
container compose cp --follow-link api:/tmp/current ./current
```

Expected behavior:

- The selected service container source symlink is dereferenced by the fork-backed runtime.
- Existing `cp` behavior remains unchanged without `--follow-link`.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
