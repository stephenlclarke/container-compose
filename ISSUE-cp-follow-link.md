# Feature request: support `container compose cp --follow-link`

## Feature or enhancement request details

Docker Compose exposes `docker compose cp -L, --follow-link` to copy the target of a symbolic link in `SRC_PATH`. `container-compose` previously rejected this option because released upstream `apple/container` did not expose copy follow-link controls.

The local integration stack now carries fork-backed `followSymlink` support through `containerization` and `apple/container`, so the plugin can map the Compose flag through its direct copy adapter.

References:

- Docker Compose `cp --follow-link`: <https://docs.docker.com/reference/cli/docker/compose/cp/>
- Docker `container cp --follow-link`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Runtime handoff files in the container fork: `ISSUE-copy-follow-link.md` and `PR-copy-follow-link.md`
- Lower runtime handoff files in the containerization fork: `ISSUE-containerization-copy-follow-link.md` and `PR-containerization-copy-follow-link.md`

## Proposed behavior

- Accept `container compose cp --follow-link` / `-L`.
- Pass the option through direct `ContainerClient.copyIn` / `copyOut` calls.
- Apply the option to service-to-service copies only for the source container copy-out leg.
- Keep `cp --archive` rejected until the runtime exposes archive ownership controls.

## Minimal example

```sh
container compose cp --follow-link api:/tmp/current ./current
```

Expected behavior:

- The selected service container source symlink is dereferenced by the fork-backed runtime.
- Existing `cp` behavior remains unchanged without `--follow-link`.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
