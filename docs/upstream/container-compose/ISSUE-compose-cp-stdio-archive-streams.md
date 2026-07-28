# Compose compatibility gap: `cp -` archive streams

## Compose surface

`container compose cp - SERVICE:PATH` and `container compose cp SERVICE:PATH -`

## Docker Compose v2 behavior

Docker Compose treats `-` as a tar archive stream for `cp`. When the source operand is `-`, Compose reads a tar archive from stdin and extracts the archive members into the service container destination. When the destination operand is `-`, Compose copies the requested service container path and writes a tar archive to stdout.

References:

- Docker `container cp` reference: <https://docs.docker.com/reference/cli/docker/container/cp/>
- Docker Compose `cp` reference: <https://docs.docker.com/reference/cli/docker/compose/cp/>
- Adjacent Apple PR: [apple/container#1832](https://github.com/apple/container/pull/1832) covers file-descriptor staging for image load input, not container filesystem copy streams.
- Copy-out lifecycle dependency: [apple/container#1927](https://github.com/apple/container/issues/1927) / [apple/containerization#799](https://github.com/apple/containerization/pull/799).
- Direct-stream proposals: [apple/containerization#812](https://github.com/apple/containerization/pull/812) and [apple/container#1947](https://github.com/apple/container/pull/1947).

## Current container-compose behavior

`container-compose` supports stdin and stdout tar archive operands for `cp` in the Compose layer. It stages stream data through temporary host paths, then uses the existing Apple path-copy primitives:

- stdin archive streams are extracted with libarchive and each top-level member is copied into the selected service container destination.
- service-container source paths are staged to a temporary host directory, archived with libarchive, and written to stdout without text decoding.
- direct path copies, service-to-service copies, `--archive`, `--follow-link`, `--index`, and `--all` stay on the existing copy paths.
- missing service-container source paths rely on the matched `stephenlclarke/containerization` copy-out lifecycle fix so failures return promptly and do not block later container operations.
- the current live fixture matches Docker Compose v5.3.1 for content, modes, symlinks, sparse allocation, long paths, and large files. Host-staged archive input does not preserve arbitrary UID/GID or timestamps and rejects hard-link entries.

## Likely owner

Apple runtime stream primitive followed by a container-compose adapter.

The content behavior is implemented in `container-compose`, and its support is now classified as partial. Complete user-visible archive-metadata parity requires a reviewed direct stream API so tar headers reach the runtime without host materialisation.

## Minimal example

```yaml
services:
  app:
    image: alpine
    command: ["sh", "-c", "sleep 120"]
```

```sh
tar -cf - payload.txt | container compose cp - app:/tmp
container compose cp app:/tmp/payload.txt - > payload.tar
```

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct
- [x] I checked STATUS.md and the relevant command help
