# Add a Linux virtio-gpu device configuration

## Summary

`containerization` should expose a small, typed Linux VM graphics toggle so callers can request the Virtualization.framework virtio-gpu device when a container needs the generic GPU surface.

## Current Gap

Virtualization.framework exposes `VZVirtioGraphicsDeviceConfiguration`, and `container-compose` needs a lower-runtime primitive for Docker-compatible generic GPU requests. Without a typed configuration value, higher layers either reject `--gpus`/Compose `gpus` or need to know Virtualization.framework details directly.

## Proposed Shape

- Add a `graphicsDevice` Boolean to the Linux container VM configuration.
- Translate `graphicsDevice == true` to a `VZVirtioGraphicsDeviceConfiguration`.
- Keep display policy minimal and avoid Docker Compose-specific behavior in `containerization`.
- Keep vendor/native GPU passthrough, Metal, CUDA, and arbitrary PCI device passthrough out of this primitive.

## Upstream References

- [apple/containerization#480](https://github.com/apple/containerization/issues/480): GPU support request.
- [apple/containerization#569](https://github.com/apple/containerization/pull/569): upstream virtio-gpu proposal imported as the base shape for the local fork.
- [apple/container#1511](https://github.com/apple/container/issues/1511): higher-level `--gpus` request.

## Acceptance Criteria

- A caller can set a typed graphics-device flag on Linux VM configuration.
- The Virtualization.framework VM receives a virtio-gpu configuration only when that flag is true.
- Existing Linux container configurations remain unchanged when the flag is false.
- The guest kernel configuration enables the virtio DRM driver needed to expose `/dev/dri` nodes.
- Unit coverage proves the typed flag is forwarded to VM construction.

## Ownership

`containerization` owns the VM/device configuration and guest kernel support. `apple/container` owns CLI/API policy and OCI device-node projection. `container-compose` owns Docker Compose model validation and service/deploy mapping.

## Validation

```bash
make test
make check
```

## Notes

This is generic paravirtual graphics support. It does not provide direct host GPU passthrough, vendor driver access, Metal, CUDA, or multiple GPU selection.
