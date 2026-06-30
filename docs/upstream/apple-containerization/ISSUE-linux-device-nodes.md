# Feature or Enhancement Request Details

`apple/containerization` needs a typed way for callers to add OCI Linux device nodes to generated runtime specs.

The current runtime spec generator already builds OCI process, namespace, mount, and resource sections. Docker-compatible higher layers need the adjacent `linux.devices` field so a caller can request a device node such as `/dev/xnull` with a known major/minor pair and file metadata.

The Apple-shaped primitive is intentionally runtime-native:

- expose `LinuxContainer.Configuration.devices` as `[ContainerizationOCI.LinuxDevice]`;
- default the value to an empty array so existing callers behave exactly as before;
- assign the value to `Spec.linux.devices` during runtime spec generation;
- leave Docker/Compose string parsing, source path resolution, and host hardware passthrough decisions to higher layers.

This is needed by `stephenlclarke/container` so its Linux runtime-data bridge can resolve supported Linux VM device paths and populate OCI `linux.devices` without adding Compose-specific policy to the lower runtime.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
