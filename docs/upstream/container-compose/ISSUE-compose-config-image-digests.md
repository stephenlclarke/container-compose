# Support `compose config` Image Digest Pinning

## Summary

`container compose config --resolve-image-digests` and `container compose config --lock-image-digests` should be accepted and should pin explicit service image tags to registry manifest digests without importing image content into the local store.

The plugin already renders canonical config, service projections, and output files. The missing piece is digest resolution for explicit `services.*.image` references. Build-only services without an explicit image do not have a remote tag to pin and should be left unchanged.

## Acceptance Criteria

- `container compose help config` shows `config` as supported.
- `container compose help config` shows `--resolve-image-digests` and `--lock-image-digests` as supported.
- `config --resolve-image-digests` renders canonical config with selected service images pinned as `name:tag@sha256:...`.
- `config --lock-image-digests` renders a deterministic override file under `services:` with pinned image references.
- Already digest-pinned images are preserved without an extra registry lookup.
- Focused unit tests cover the async resolver path and help/parser support.
- An opt-in runtime smoke verifies real registry HEAD resolution for both modes.

## Notes

This is a Compose-side change. It reuses the public `ContainerizationOCI.RegistryClient.resolve` HEAD path and does not require a new Apple runtime API or a local image pull.
