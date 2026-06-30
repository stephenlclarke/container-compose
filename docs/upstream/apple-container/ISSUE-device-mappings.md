# Feature or Enhancement Request Details

`apple/container` needs a Docker-compatible `--device` runtime bridge for supported Linux VM device paths.

Docker exposes this through `docker run --device HOST[:CONTAINER[:PERMISSIONS]]`, and Docker Compose exposes the same behavior through service `devices`:

```bash
container run --device /dev/null:/dev/xnull:rw IMAGE
container run --device /dev/zero IMAGE
```

The useful Apple-facing shape is a Linux-specific runtime-data bridge:

- parse Docker-compatible device mapping values at the CLI/API boundary;
- carry source, target, and permissions through `LinuxRuntimeData` in `RuntimeConfiguration.runtimeData`;
- have the Linux runtime resolve source paths inside the Linux runtime VM;
- generate OCI `linux.devices` entries and matching `linux.resources.devices` allow rules;
- keep USB, SD-card, PCI, GPU, and arbitrary macOS hardware passthrough outside this primitive.

Existing upstream context reviewed while scoping this slice:

- [apple/container#640](https://github.com/apple/container/issues/640): USB/SD sharing, labeled as needing virtualization support.
- [apple/container#1680](https://github.com/apple/container/issues/1680): USB redirection request.
- [apple/container#1683](https://github.com/apple/container/issues/1683): SD-card block-device redirection request.
- [apple/container#1511](https://github.com/apple/container/issues/1511): `--gpus` request.
- [apple/containerization#74](https://github.com/apple/containerization/issues/74): USB support via USB/IP.
- [apple/containerization#480](https://github.com/apple/containerization/issues/480) and [apple/containerization#569](https://github.com/apple/containerization/pull/569): broader GPU context.
- [apple/container discussion #1469](https://github.com/apple/container/discussions/1469) and [discussion #62](https://github.com/apple/container/discussions/62): passthrough demand signals.

This change is intentionally narrower than true macOS hardware passthrough. It maps known Linux VM device paths such as `/dev/null` and `/dev/zero` into the container spec and fails clearly for unknown sources until guest-side device discovery or host-passthrough primitives exist.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
