# Add a Linux virtio-gpu device configuration

## Summary

`containerization` should expose a small, typed Linux VM graphics toggle so callers can request the Virtualization.framework virtio-gpu device when a container needs the generic GPU surface.

## Current Gap

Virtualization.framework exposes `VZVirtioGraphicsDeviceConfiguration`, and `container-compose` needs a lower-runtime primitive for Docker-compatible generic GPU requests. Without a typed configuration value, higher layers either reject `--gpus`/Compose `gpus` or need to know Virtualization.framework details directly.

## Proposed Shape

- Add a typed Linux VM graphics configuration with disabled, device-only, and display scanout modes.
- Translate enabled graphics configuration to a `VZVirtioGraphicsDeviceConfiguration`.
- Add a generic guest-device discovery hook that resolves already-created guest device nodes with `stat` before OCI process start.
- Keep display policy minimal and avoid Docker Compose-specific behavior in `containerization`.
- Keep vendor/native GPU passthrough, Metal, CUDA, and arbitrary PCI device passthrough out of this primitive.

## Upstream References

- [apple/containerization#480](https://github.com/apple/containerization/issues/480): GPU support request.
- [apple/containerization#569](https://github.com/apple/containerization/pull/569): upstream virtio-gpu proposal imported as the base shape for the local fork.
- [apple/container#1511](https://github.com/apple/container/issues/1511): higher-level `--gpus` request.

## Acceptance Criteria

- A caller can set a typed graphics-device configuration on Linux VM configuration.
- The Virtualization.framework VM receives a virtio-gpu configuration only when graphics are enabled.
- Existing Linux container configurations remain unchanged when the flag is false.
- The in-repo guest kernel configurations enable the virtio DRM driver needed to expose `/dev/dri` nodes when those kernels are used.
- Guest device requests are resolved from the booted VM so device type, major/minor, mode, uid, and gid come from the running guest rather than a static table.
- Unit coverage proves the typed graphics configuration is forwarded to VM construction.
- Runtime integration coverage should boot the guest kernel and record whether the active kernel exposes DRM nodes before documenting a specific `/dev/dri` shape or claiming accelerated rendering.

## Ownership

`containerization` owns the VM/device configuration and guest kernel support. `apple/container` owns CLI/API policy and OCI device-node projection. `container-compose` owns Docker Compose model validation and service/deploy mapping.

## Validation

```bash
make test
make check
```

## Notes

This is generic paravirtual graphics-device support. It does not prove hardware-accelerated rendering and does not provide direct host GPU passthrough, vendor driver access, Metal, CUDA, or multiple GPU selection.
