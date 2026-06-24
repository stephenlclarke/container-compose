# Feature or Enhancement Request Details

`apple/container` needs a Linux block I/O tuning primitive so higher-level tooling can pass typed resource controls without dropping them. Docker exposes this through `docker run --blkio-weight`, `--blkio-weight-device`, `--device-read-bps`, `--device-write-bps`, `--device-read-iops`, and `--device-write-iops`; Docker Compose exposes the same capability through `services.<name>.blkio_config`.

Existing upstream context:

- [apple/container#1512](https://github.com/apple/container/issues/1512) tracks block I/O controls in `apple/container`.
- [apple/container#1595](https://github.com/apple/container/pull/1595), opened by Chris George, proposes the `container run/create --blkio` contract used here.
- [apple/containerization#739](https://github.com/apple/containerization/pull/739), also opened by Chris George, adds the lower-level `Containerization.LinuxBlockIO` API that the runtime needs.

This local integration branch should build on those PRs, not replace them. The useful Apple-facing shape is the lower-runtime `Containerization.LinuxBlockIO` model plus an `apple/container` typed runtime-data bridge. Chris George's #1595 also proposes a repeatable key-value CLI option:

```bash
container run --blkio weight=500 IMAGE
container run --blkio device=/dev/sda,weight=700,leaf-weight=300 IMAGE
container run --blkio device=8:0,read-bps=1048576,write-iops=1000 IMAGE
```

The design keeps block I/O data out of `ContainerConfiguration.Resources` because it is Linux-specific. The typed bridge encodes an OCI block I/O wire model into `LinuxRuntimeData`, and the Linux runtime converts it to `Containerization.LinuxBlockIO` when configuring `LinuxContainer`.

This is needed by `stephenlclarke/container-compose` so Compose `blkio_config` can map to typed OCI block I/O data while the lower-level runtime remains owned by `apple/container` and `apple/containerization`. After JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), the Compose plugin should own Docker/Compose `blkio_config` parsing; any `--blkio` parser in the local fork is a temporary validation bridge, not the required upstream shape.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
