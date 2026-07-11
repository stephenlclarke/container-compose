# Feature request: expose `container cp` tar archive streaming

<!-- markdownlint-disable MD013 -->

## Feature or enhancement request details

Docker exposes tar archive streaming through `docker cp` and `docker compose cp` when either copy operand is `-`. Copying from stdin into a container extracts the provided tar stream at the destination. Copying from a container to stdout writes a tar archive for the requested source path.

`apple/container` currently exposes path-based `copyIn` and `copyOut` APIs. The lower `containerization` runtime streams archive data internally over vsock, but the public CLI/API boundary accepts host filesystem paths rather than a caller-provided input stream or caller-owned output stream. That means `container-compose` cannot implement Docker-compatible `compose cp - SERVICE:PATH` or `compose cp SERVICE:PATH -` without either staging and re-archiving data with lossy edge cases or adding a first-class Apple runtime copy stream primitive.

References:

- Docker `container cp`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Docker Compose `cp`: <https://docs.docker.com/reference/cli/docker/compose/cp/>
- Nearby Apple context: `apple/container#1832` covers image load from file descriptor input; it is adjacent stdin/archive handling but not container filesystem copy streaming.
- Nearby Apple context: `apple/container#963` and `apple/container#895` cover volume copy, which is adjacent but not a replacement for container copy stdin/stdout archive streaming.
- Nearby Apple context: `apple/container#1391` covers archive writer behavior for build-context entries and symlinks, but does not expose `container cp -`.

Existing upstream context:

- `container-compose` now rejects `compose cp` operands equal to `-` with a precise unsupported-feature message instead of treating `-` as a literal local filename.

## Proposed behavior

- Add stream-oriented copy API entry points for copying a tar archive stream into a container path and copying a container path out as a tar archive stream.
- Add `container cp - CONTAINER:/path` and `container cp CONTAINER:/path -` CLI support that mirrors Docker tar stream semantics.
- Keep existing path-based copy APIs source-compatible.
- Preserve existing `--archive` and `--follow-link` behavior where it applies to streamed copy operations.

## Minimal examples

```sh
tar -cf - payload.txt | container cp - demo:/tmp
container cp demo:/tmp/payload.txt - > payload.tar
```

Expected behavior:

- The first command extracts `payload.txt` under `/tmp` in the running container.
- The second command writes a tar archive containing `payload.txt` to stdout.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
