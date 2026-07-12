# Pull Request

## Summary

- Add a typed Linux VM graphics-device flag.
- Configure Virtualization.framework with `VZVirtioGraphicsDeviceConfiguration` when requested.
- Enable the guest virtio DRM kernel option.
- Add regression coverage that proves the flag reaches VM construction.

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

- Adds `graphicsDevice` to the Linux container configuration model.
- Threads the flag through VM manager and VM instance creation.
- Creates `VZVirtioGraphicsDeviceConfiguration` only when the flag is true.
- Enables `CONFIG_DRM_VIRTIO_GPU=y` in the guest kernel config.
- Keeps scanout/display policy intentionally minimal and avoids Docker Compose-specific naming or validation.

## Compatibility Notes

- Existing configurations keep graphics disabled by default.
- The primitive exposes paravirtual graphics only. Direct Metal/CUDA/vendor GPU passthrough, arbitrary PCI passthrough, and multiple GPU selection remain out of scope.

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
