# Pull Request

## Summary

- Add repeatable `container run/create --gpus` parsing.
- Carry Docker-compatible GPU requests through Linux runtime data.
- Validate the supported Apple virtio-gpu subset before VM creation.
- Enable the lower-runtime graphics device and project discovered virtio-gpu DRM character-device metadata into the OCI config.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker-compatible Compose support needs a runtime bridge for generic GPU requests. The requested upstream surface is tracked in [apple/container#1511](https://github.com/apple/container/issues/1511), with lower-runtime context in [apple/containerization#480](https://github.com/apple/containerization/issues/480) and [apple/containerization#569](https://github.com/apple/containerization/pull/569). This PR keeps the Apple-facing code generic and leaves Compose-specific validation and service/deploy mapping in `container-compose`.

## Implementation Details

- Adds `LinuxGPURequest` to the Linux runtime-data payload with a backward-compatible decode default.
- Adds `--gpus <gpu-request>` to run/create management flags.
- Parses Docker-compatible request CSV, including quoted capabilities/options fields.
- Accepts only the Apple virtio-gpu subset: one generic GPU, optional `driver=virtio`, device ID `0`, no options, and no extra capabilities.
- Requests the common virtio-gpu DRM nodes (`/dev/dri/card0` and `/dev/dri/renderD128`) as optional guest discoveries; the lower runtime resolves type, major/minor, mode, uid, and gid from the booted guest before OCI process start when the guest exposes them.
- Sets the lower-runtime `graphicsDevice` flag for supported requests.

## Compatibility Notes

- Existing runtime data without `gpuRequests` still decodes with no GPU request.
- Unsupported request forms fail early with explicit diagnostics.
- This does not implement direct Metal/CUDA/vendor GPU passthrough, multiple GPUs, arbitrary device IDs, driver options, PCI passthrough, arbitrary host hardware passthrough, or verified hardware-accelerated rendering.

## Validation

```bash
swift test --filter 'ParserTest|ContainerRunCreateCommandTests|RuntimeConfigurationTests|RuntimeServiceHostsTests'
make test
make check
```

## Checklist

- [x] Recorded upstream issue and PR references.
- [x] Added parser, CLI, runtime-data, and OCI projection tests.
- [x] Kept Compose-specific policy out of `apple/container`.
- [x] Avoided pushing changes to Apple remotes.
