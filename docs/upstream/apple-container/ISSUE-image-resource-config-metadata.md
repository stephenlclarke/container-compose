# Expose image config metadata through ImageResource

## Summary

`apple/container` should expose generic image config labels and exposed ports through `ImageResource.Variant`. Higher-level tools need these fields when selecting local image variants and filtering images by ordinary image-config metadata.

## Expected Behavior

- `ImageResource.Variant` exposes image config labels as a string dictionary.
- `ImageResource.Variant` exposes Docker image config exposed-port keys as a sorted string list.
- Missing labels and exposed ports return empty collections.
- No Docker Compose CLI parsing or Bridge conversion policy enters `apple/container`.

## Ownership

`apple/container` owns the image resource projection over `containerization` image config data. `container-compose` owns Compose Bridge commands, transformer discovery policy, and model enrichment.

## Upstream Context

- Docker Compose Bridge transformer images are identified by the `com.docker.compose.bridge=transformation` image label in Docker's Bridge implementation: <https://github.com/docker/compose/blob/main/pkg/bridge/transformers.go>.
- Docker's default transformer image Dockerfile carries that label: <https://github.com/docker/compose-bridge-transformer/blob/main/Dockerfile>.
- The current upstream Apple search did not find an existing `apple/container` issue or PR for projecting image config labels and exposed ports through `ImageResource`.

## Validation Expectations

- An image resource variant backed by config labels exposes those labels.
- A variant backed by `ExposedPorts` exposes sorted `port/protocol` keys.
- Existing callers that ignore these computed properties are unaffected.
