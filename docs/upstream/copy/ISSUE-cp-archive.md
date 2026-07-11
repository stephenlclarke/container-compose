# Feature request: support `container compose cp --archive`

<!-- markdownlint-disable MD013 -->

## Feature or enhancement request details

Docker Compose exposes `docker compose cp -a, --archive` to preserve source UID/GID information where possible. `container-compose` previously rejected this option because released upstream `apple/container` did not expose copy archive controls.

The local integration stack now carries fork-backed ownership preservation support through `containerization` and `apple/container`, so the plugin can map the Compose flag through its direct copy adapter.

References:

- Docker Compose `cp --archive`: <https://docs.docker.com/reference/cli/docker/compose/cp/>
- Docker `container cp --archive`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Runtime handoff files: `docs/upstream/apple-container/copy/ISSUE-copy-archive.md` and `docs/upstream/apple-container/copy/PR-copy-archive.md`
- Lower runtime handoff files: `docs/upstream/apple-containerization/copy/ISSUE-containerization-copy-archive-ownership.md` and `docs/upstream/apple-containerization/copy/PR-containerization-copy-archive-ownership.md`

Existing upstream context:

- `apple/container#232` requested the original `container cp` command.
- `apple/container#1190` merged the current host-container copy command.
- `apple/container#1579` and `apple/container#1580` added copy coverage and FilePath cleanup.
- `apple/container#1738`, `apple/container#1741`, `apple/container#1743`, and `apple/container#1749` cover nearby host path resolution behavior.
- `apple/container#963` and `apple/container#895` cover volume copy, which is adjacent but not a replacement for archive ownership preservation.
- `apple/container#1391` covers archiver behavior for build context entries and symlinks, but does not expose `container cp --archive`.
- `apple/container#165` and `apple/container#787` discuss adjacent UID/GID and ownership behavior for bind mounts and volumes, but not copy archive mode.
- `apple/containerization#571`, `apple/containerization#614`, `apple/containerization#636`, and `apple/containerization#727` are relevant lower-level copy/stat/UID-GID context.

## Proposed behavior

- Accept `container compose cp --archive` / `-a`.
- Pass the option through direct `ContainerClient.copyIn` / `copyOut` calls.
- Request ownership preservation on both host-staging legs for service-to-service copies.
- Keep default copy behavior unchanged when the flag is not provided.

## Minimal example

```sh
container compose cp --archive api:/tmp/report.txt ./report.txt
```

Expected behavior:

- The selected service container source UID/GID is preserved by the fork-backed runtime where host permissions allow it.
- Existing `cp` behavior remains unchanged without `--archive`.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
