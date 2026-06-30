# Feature or Enhancement Request Details

`apple/container` needs a Linux device cgroup rule primitive so callers can configure OCI `linux.resources.devices` without requiring host-device passthrough.

Docker exposes this through `docker run --device-cgroup-rule`, and Docker Compose exposes the same rule strings through `services.<name>.device_cgroup_rules`:

```bash
container run --device-cgroup-rule "c 1:3 mr" IMAGE
container run --device-cgroup-rule "a *:* rwm" IMAGE
```

The useful Apple-facing shape is a Linux-specific runtime-data bridge:

- parse or accept typed device cgroup rules at the CLI/API boundary;
- carry the rules through `LinuxRuntimeData` in `RuntimeConfiguration.runtimeData`;
- have the Linux runtime assign those rules to `LinuxContainer.Configuration.deviceCgroupRules`;
- keep host device injection, GPU passthrough, and Compose service policy outside this primitive.

Existing upstream context reviewed while scoping this slice:

- [apple/container#1683](https://github.com/apple/container/issues/1683): SD-card block-device redirection request.
- [apple/container#1680](https://github.com/apple/container/issues/1680): USB redirection request.
- [apple/container#1511](https://github.com/apple/container/issues/1511): `--gpus` request.
- [apple/container#640](https://github.com/apple/container/issues/640): USB/SD sharing, labeled as needing virtualization support.
- [apple/container#1512](https://github.com/apple/container/issues/1512) and [apple/container#1595](https://github.com/apple/container/pull/1595): adjacent block I/O cgroup runtime work and a useful runtime-data pattern.
- [apple/containerization#74](https://github.com/apple/containerization/issues/74), [apple/containerization#480](https://github.com/apple/containerization/issues/480), and [apple/containerization#569](https://github.com/apple/containerization/pull/569): broader device/GPU runtime context.
- [apple/container discussion #1469](https://github.com/apple/container/discussions/1469) and [discussion #62](https://github.com/apple/container/discussions/62): passthrough demand signals.

This change is intentionally narrower than those passthrough requests. Device cgroup rules set permissions in the OCI runtime spec; they do not mount or expose host devices by themselves.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
