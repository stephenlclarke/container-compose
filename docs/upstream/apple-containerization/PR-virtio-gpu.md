# Pull Request

## Summary

- Add a typed Linux VM graphics-device configuration.
- Configure Virtualization.framework with `VZVirtioGraphicsDeviceConfiguration` when requested.
- Enable the guest virtio DRM kernel option in the in-repo kernel configs.
- Add guest-device discovery and regression coverage that proves the flag reaches VM construction.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker-compatible callers need a lower-runtime way to request the generic GPU surface without embedding Virtualization.framework details or Docker Compose policy in every caller. The local fork follows the useful shape from [apple/containerization#569](https://github.com/apple/containerization/pull/569) for [apple/containerization#480](https://github.com/apple/containerization/issues/480), then keeps the behavior narrow: a single Apple virtio-gpu device and matching guest kernel support.

Related upstream references:

- [apple/containerization#480](https://github.com/apple/containerization/issues/480)
- [apple/containerization#569](https://github.com/apple/containerization/pull/569)
- [apple/container#1511](https://github.com/apple/container/issues/1511)

## Implementation Details

- Adds `GraphicsConfiguration` with disabled, device-only, and display scanout modes to the Linux container configuration model.
- Threads the typed graphics configuration through VM manager and VM instance creation.
- Creates `VZVirtioGraphicsDeviceConfiguration` only when graphics are enabled.
- Validates display scanout dimensions before constructing the Virtualization.framework graphics device.
- Adds `LinuxGuestDeviceRequest` so callers can request guest-created device nodes and resolve OCI device/cgroup metadata from `stat` against the booted VM.
- Enables `CONFIG_DRM_VIRTIO_GPU=y` in the guest kernel configs so kernels built from this repo can expose `/dev/dri` nodes for the attached virtio-gpu device.
- Keeps scanout/display policy intentionally minimal and avoids Docker Compose-specific naming or validation.

## Compatibility Notes

- Existing configurations keep graphics disabled by default.
- The primitive exposes a paravirtual graphics device only. Direct Metal/CUDA/vendor GPU passthrough, arbitrary PCI passthrough, multiple GPU selection, and claims of hardware-accelerated rendering remain out of scope. Runtime integration records whether the active guest kernel exposes DRM nodes before documenting a specific `/dev/dri` shape.

## Validation

```bash
make test
make check
```

## Checklist

- [x] Recorded upstream issue and PR references.
- [x] Added or updated focused tests.
- [x] Kept Docker Compose policy out of `containerization`.
- [x] Avoided pushing changes to Apple remotes.
