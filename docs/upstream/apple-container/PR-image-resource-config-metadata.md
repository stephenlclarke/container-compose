# Expose image config metadata through ImageResource

## Summary

- Add `ImageResource.Variant.imageConfigLabels`.
- Add `ImageResource.Variant.exposedPorts`.
- Add focused image resource test coverage using Docker-compatible labels and `ExposedPorts` fixture data.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Higher-level tools need to inspect local image metadata without depending on raw `ImageConfig` internals. Compose Bridge uses two generic pieces of image config metadata: labels for transformer discovery and exposed ports for model enrichment. Exposing those values through `ImageResource.Variant` gives callers a small Apple-shaped API while keeping Docker Compose policy out of `apple/container`.

## Commit Tracking

- Container resource projection commit: `380ff28` in `stephenlclarke/container` (`feat(image): expose config metadata`).
- Lower `containerization` dependency commit: `dcde0cd` in `stephenlclarke/containerization` (`feat(oci): decode Docker exposed ports`).
- Compose Bridge runtime code is tracked in `docs/upstream/container-compose/PR-compose-bridge-cli.md`.

## Implementation Details

- Added computed `imageConfigLabels` that returns `config.config?.labels ?? [:]`.
- Added computed `exposedPorts` that returns sorted keys from `config.config?.exposedPorts ?? [:]`.
- Kept the properties read-only and variant-scoped because labels and exposed ports are image config metadata, not mutable runtime resource state.

## Testing

```bash
swift test --filter ClientImageImageResourceTests --no-parallel
```

## Compatibility Notes

The change only adds read-only computed accessors. Existing resource JSON decoding and callers remain compatible.
