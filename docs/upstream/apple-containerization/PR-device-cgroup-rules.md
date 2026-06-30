# Pull request: allow Linux device cgroup rules in runtime specs

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change gives `LinuxContainer` callers a typed way to add OCI Linux device cgroup rules to generated runtime specs. Higher layers can use this for Docker-compatible `--device-cgroup-rule` or Compose `device_cgroup_rules` support without asking `containerization` to parse Docker strings or make host-device passthrough decisions.

The API stays Apple-shaped and runtime-native: callers provide `[ContainerizationOCI.LinuxDeviceCgroup]` through `LinuxContainer.Configuration.deviceCgroupRules`, and `generateRuntimeSpec()` assigns those values to `linux.resources.devices`.

## Commit Tracking

- Lower runtime code commit: `df62b48377b7f2ea0693a02ee4dd0a176756bc2a` in `stephenlclarke/containerization` (`feat(runtime): allow device cgroup rules`).
- Container API/CLI commit: `670aa761305135f593e42256579c07fd9722c7d4` in `stephenlclarke/container` (`feat(runtime): add device cgroup rule flag`), tracked separately in `docs/upstream/apple-container/PR-device-cgroup-rules.md`.
- Compose integration code is tracked in `docs/upstream/container-compose/PR-device-cgroup-rules.md`.

## Implementation Details

- Added `deviceCgroupRules` to `LinuxContainer.Configuration`, defaulting to `[]`.
- Added the same default to the configuration initializer.
- Updated `generateRuntimeSpec()` so `LinuxResources` receives configured device cgroup rules alongside memory, CPU, and block I/O resources.
- Added a focused runtime-spec unit test for character-device and all-device rules.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter LinuxContainerTests/runtimeSpecIncludesConfiguredDeviceCgroupRules
swift test --filter LinuxContainerTests
git diff --check
```

## Compatibility Notes

- Default behavior is unchanged because `deviceCgroupRules` defaults to an empty array.
- This does not expose Docker or Compose syntax in `containerization`.
- Device node creation is handled by the later OCI device-node slice. This cgroup-rule slice does not implement GPU or arbitrary macOS hardware passthrough; it only projects cgroup permission rules into the OCI spec.

## Remaining Risks

- Higher layers must still validate Docker-compatible rule strings or construct valid `LinuxDeviceCgroup` values.
- Host-device availability remains separate from cgroup permissions.
