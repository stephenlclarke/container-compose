# Feature or Enhancement Request Details

`apple/containerization` needs a typed way for callers to add OCI Linux device cgroup rules to generated runtime specs.

The current runtime spec generator already builds OCI Linux resources for memory, CPU, and block I/O controls. Device cgroup rules belong in the same generated `linux.resources.devices` block, but callers need an API surface on `LinuxContainer.Configuration` to provide them.

The Apple-shaped primitive is intentionally runtime-native:

- expose `LinuxContainer.Configuration.deviceCgroupRules` as `[ContainerizationOCI.LinuxDeviceCgroup]`;
- default the value to an empty array so existing callers behave exactly as before;
- assign the rules into `LinuxResources(devices: ...)` during runtime spec generation;
- leave Docker/Compose string parsing and host-device passthrough decisions to higher layers.

This is needed by `stephenlclarke/container` so its Linux runtime-data bridge can configure device cgroup permissions without adding Compose-specific policy to the lower runtime.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
