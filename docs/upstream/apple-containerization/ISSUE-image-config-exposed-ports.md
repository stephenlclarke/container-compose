# Decode Docker image config exposed ports

## Summary

`containerization` should preserve Docker image config `ExposedPorts` when decoding OCI image config JSON. Higher-level callers need this generic metadata to inspect local images and decide which ports an image declares without re-parsing raw image JSON.

## Expected Behavior

- `ContainerizationOCI.ImageConfig` decodes `Config.ExposedPorts` from Docker-compatible image config JSON.
- The decoded value is optional and absent by default for images that do not declare exposed ports.
- The model remains a generic OCI/Docker image metadata representation; no Compose Bridge behavior enters `containerization`.

## Ownership

`containerization` owns the image config model. `apple/container` owns the resource projection exposed by `ImageResource`. `container-compose` owns Docker Compose Bridge behavior and converts exposed-port metadata into Compose model `expose` entries when running transformers.

## Upstream Context

- Docker Compose Bridge enriches models with image metadata before conversion and includes image config exposed ports in the converted model input: <https://github.com/docker/compose/blob/main/pkg/bridge/convert.go>.
- The current upstream Apple search did not find an existing `apple/containerization` issue or PR for decoding Docker image config `ExposedPorts`.

## Validation Expectations

- Encoding and decoding an image config with `ExposedPorts` round-trips the port map.
- Decoding Docker-compatible image config JSON with `8080/tcp` exposes that key.
- Existing image config callers that omit the field keep current behavior.
