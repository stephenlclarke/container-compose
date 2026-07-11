# Feature request: preserve ownership metadata for archive-mode copy

<!-- markdownlint-disable MD013 -->

## Feature or enhancement request details

Docker exposes `docker cp -a, --archive` and Docker Compose exposes `docker compose cp -a, --archive` as archive mode that copies UID/GID information. `apple/container` can copy files through `containerization`, but the lower copy protocol does not currently carry ownership metadata for single-file raw transfers.

Directory copies already use a tar archive stream, which carries entry ownership metadata. Single-file copies use a raw byte stream, so `container` and `container-compose` cannot implement archive-mode copy ownership preservation without a lower runtime metadata contract.

References:

- Docker `container cp --archive`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Docker Compose `cp --archive`: <https://docs.docker.com/reference/cli/docker/compose/cp/>

Existing upstream context:

- `apple/containerization#463` added the single-file copy agent path.
- `apple/containerization#571` added LinuxContainer directory copy support.
- `apple/containerization#614` added stat metadata support.
- `apple/containerization#636` fixed UID/GID truncation to 16 bits.
- `apple/containerization#727` added path resolution for copy-in using stat.

## Proposed behavior

- Add a `preserve_ownership` control flag to the copy request.
- For host-to-guest single-file copies, pass the source UID/GID and mode to `vminitd` and apply them after the raw write.
- For guest-to-host single-file copies, return source UID/GID and mode in copy metadata so the host copy path can apply them when requested.
- Preserve existing copy behavior when the flag is not set.
- Keep directory copies on the existing archive stream path.

## Minimal example

```sh
container cp --archive ./owned-file demo:/tmp/owned-file
container cp --archive demo:/tmp/owned-file ./owned-file
```

Expected behavior:

- The runtime attempts to preserve UID/GID information for single-file copies when archive mode is requested.
- Existing copy calls remain source-compatible and keep their current default behavior.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
