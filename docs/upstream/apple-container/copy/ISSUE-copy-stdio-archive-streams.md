# Feature request: expose `container cp` tar archive streaming

<!-- markdownlint-disable MD013 -->

## Feature or enhancement request details

Docker exposes tar archive streaming through `docker cp` and `docker compose cp` when either copy operand is `-`. Copying from stdin into a container extracts the provided tar stream at the destination. Copying from a container to stdout writes a tar archive for the requested source path.

`apple/container` currently exposes path-based `copyIn` and `copyOut` APIs. The lower `containerization` runtime streams archive data internally over vsock, but the public CLI/API boundary accepts host filesystem paths rather than a caller-provided input stream or caller-owned output stream.

During testing of my Container Compose plugin, I found that the path-only API cannot preserve complete tar semantics without extracting archive members on the host. The supported fork now demonstrates a first-class stream contract: the current live fixture matches Docker for content, ownership, modes, timestamps, symlinks, hard links, sparse allocation, long paths, and large files. Stock Apple still needs an equivalent primitive so callers can obtain that fidelity without carrying fork-only runtime APIs.

References:

- Docker `container cp`: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Docker Compose `cp`: <https://docs.docker.com/reference/cli/docker/compose/cp/>
- Nearby Apple context: `apple/container#1832` covers image load from file descriptor input; it is adjacent stdin/archive handling but not container filesystem copy streaming.
- Nearby Apple context: `apple/container#963` and `apple/container#895` cover volume copy, which is adjacent but not a replacement for container copy stdin/stdout archive streaming.
- Nearby Apple context: `apple/container#1391` covers archive writer behavior for build-context entries and symlinks, but does not expose `container cp -`.
- Current implementation proposals: `apple/containerization#812` and `apple/container#1947` are open, mergeable, blocked drafts that require full metadata, cancellation, backpressure, and path-safety review before adoption.

Existing upstream context:

- `container-compose` accepts `compose cp` operands equal to `-` and uses caller-owned archive handles when the matched runtime advertises the capability.
- Expanded Docker Compose v5.3.1 parity evidence confirms the direct-stream contract preserves ownership, timestamps, hard links, sparse allocation, content, and path fidelity.
- The path-based fallback remains source-compatible for alternate providers but cannot provide the same archive-fidelity guarantee.

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
