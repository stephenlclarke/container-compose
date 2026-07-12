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

## Current container-compose behavior

`container-compose` supports stdin and stdout tar archive operands for `cp` in the Compose layer. It stages stream data through temporary host paths, then uses the existing Apple path-copy primitives:

- stdin archive streams are extracted with libarchive and each top-level member is copied into the selected service container destination.
- service-container source paths are staged to a temporary host directory, archived with libarchive, and written to stdout without text decoding.
- direct path copies, service-to-service copies, `--archive`, `--follow-link`, `--index`, and `--all` stay on the existing copy paths.
- missing service-container source paths rely on the matched `stephenlclarke/containerization` copy-out lifecycle fix so failures return promptly and do not block later container operations.

## Likely owner

container-compose design gap, with an optional apple/container runtime improvement.

The Compose-compatible behavior is implemented in `container-compose`. A future Apple stream-copy API would let this project remove the temporary host staging path, but it is no longer required for user-visible Docker Compose parity.

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
