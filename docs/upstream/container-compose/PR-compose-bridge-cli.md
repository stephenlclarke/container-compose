# Implement Compose Bridge CLI runtime

## Summary

- Implements `container compose bridge convert`.
- Implements `container compose bridge transformations create`.
- Implements `container compose bridge transformations list` and `ls`.
- Adds image metadata APIs for Bridge model enrichment and transformer discovery.
- Marks Bridge commands and options supported in help, status, and CLI smoke checks.
- Adds focused unit and dry-run smoke coverage.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Bridge was a high-value Docker Compose v2 command-surface gap: the CLI help exposed the namespace but all Bridge commands were previously rejected. Docker Compose Bridge runs transformer images against a fully resolved Compose model; this plugin can now do the same with the fork-backed runtime stack because `containerization` decodes image `ExposedPorts` and `container` exposes image config labels and exposed ports through `ImageResource.Variant`.

The Docker-shaped behavior stays in `container-compose`. The Apple-backed changes are limited to generic image metadata surfaces.

## Upstream References

- Docker CLI docs for `bridge convert`: <https://docs.docker.com/reference/cli/docker/compose/bridge/convert/>
- Docker CLI docs for `bridge transformations`: <https://docs.docker.com/reference/cli/docker/compose/bridge/transformations/>
- Docker Compose Bridge model enrichment: <https://github.com/docker/compose/blob/main/pkg/bridge/convert.go>
- Docker Compose transformer discovery label: <https://github.com/docker/compose/blob/main/pkg/bridge/transformers.go>
- Default transformer image label: <https://github.com/docker/compose-bridge-transformer/blob/main/Dockerfile>

## Commit Tracking

- Lower image config dependency: `dcde0cd` in `stephenlclarke/containerization` (`feat(oci): decode Docker exposed ports`).
- Container image resource dependency: `380ff28` in `stephenlclarke/container` (`feat(image): expose config metadata`).
- Compose code is the current Bridge runtime slice in `stephenlclarke/container-compose`.

## Implementation Details

- Added `ComposeImageMetadata` and `ComposeBridgeTransformer` to the image adapter boundary.
- Added live image metadata lookup using `ClientImage.get(...).toImageResource(...)`.
- Added live transformer listing by filtering image config labels for `com.docker.compose.bridge=transformation`.
- Added `ComposeBridge.swift` for convert/list/create orchestration.
- Added Bridge `AsyncParsableCommand` implementations and help rendering.
- Added argument rewriting so project globals and Bridge `--dry-run` work in Docker Compose-compatible positions, including `bridge transformations create -f IMAGE PATH`.
- Added status and smoke-test updates so Bridge help/options render green.

## Validation

```bash
swift test --filter ComposeOrchestratorTests/bridge --no-parallel
swift test --filter ComposeArgumentRewriterTests --no-parallel
swift test --filter ComposeCLIHelpTests --no-parallel
make docker-compose-cli-surface-parity
make cli-smoke-built
git diff --check
```

## Compatibility Notes

This implements the local Bridge command surface for the fork-backed runtime lane. It does not claim Docker Desktop integration, remote Docker Engine behavior, or Docker Desktop Kubernetes deployment behavior. Transformer images must be available through the local image store or pullable by the configured `container` runtime.

## Remaining Risks

The Bridge command surface depends on fork-backed image metadata access until equivalent Apple APIs are accepted upstream and released.
