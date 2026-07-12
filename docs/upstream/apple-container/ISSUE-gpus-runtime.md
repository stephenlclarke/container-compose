# Add Docker-Compatible GPU Runtime Requests

## Summary

`apple/container` should accept Docker-compatible `--gpus` requests and project the supported generic Apple virtio-gpu device into Linux containers when the lower runtime exposes that VM device.

## Current Gap

Docker users expect `container run --gpus all` and Compose `gpus: all` / Deploy GPU reservations to be accepted when a runtime supports a GPU device. The Apple-backed runtime does not expose a Docker-compatible GPU request parser, typed runtime-data bridge, or OCI device-node projection for the Linux `/dev/dri` nodes.

## Proposed Shape

- Add repeatable `--gpus <gpu-request>` parsing to `container run` and `container create`.
- Parse Docker-compatible forms: `all`, `count=1`, `device=0`, and explicit `driver=virtio`.
- Reject unsupported vendor drivers, driver options, extra capabilities, multiple GPUs, and non-zero device IDs before the VM is created.
- Set the lower-runtime graphics flag when the request is supported.
- Project `/dev/dri/card0` and `/dev/dri/renderD128` plus matching cgroup rules into the generated OCI config.

## Upstream References

- [apple/container#1511](https://github.com/apple/container/issues/1511): `container run/create --gpus` request.
- [apple/containerization#480](https://github.com/apple/containerization/issues/480): lower-runtime GPU support request.
- [apple/containerization#569](https://github.com/apple/containerization/pull/569): virtio-gpu lower-runtime proposal.

## Acceptance Criteria

- `container run --gpus all IMAGE ...` and `container create --gpus device=0 IMAGE ...` parse successfully.
- Supported requests enable the lower-runtime graphics device.
- The Linux container receives `/dev/dri/card0` and `/dev/dri/renderD128` character devices and cgroup access.
- Unsupported GPU requests fail before VM/container creation.
- Existing runtime data remains backward-compatible when `gpuRequests` is absent.

## Ownership

`apple/container` owns Docker-compatible CLI parsing, runtime-data encoding, and OCI device-node projection. `containerization` owns the VM graphics device. `container-compose` owns Compose service/deploy mapping.

## Validation

```bash
swift test --filter 'ParserTest|ContainerRunCreateCommandTests|RuntimeConfigurationTests|RuntimeServiceHostsTests'
make test
make check
```

## Notes

The supported behavior is the single Apple virtio-gpu path. It is not direct Metal, CUDA, NVIDIA, vendor driver, multi-GPU, PCI, USB, or arbitrary macOS hardware passthrough.
