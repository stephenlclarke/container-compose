# Pull request: allow OCI Linux device nodes in runtime specs

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change gives `LinuxContainer` callers a typed way to add OCI Linux device nodes to generated runtime specs. Higher layers can use this for Docker-compatible `--device` or Compose `devices` support without asking `containerization` to parse Docker strings or resolve source device paths.

The API stays Apple-shaped and runtime-native: callers provide `[ContainerizationOCI.LinuxDevice]` through `LinuxContainer.Configuration.devices`, and `generateRuntimeSpec()` assigns those values to `linux.devices`.

## Commit Tracking

- Lower runtime code commit: `149a1f5dc9a6d42bef2224cca54bd341bcdd5c6d` in `stephenlclarke/containerization` (`feat(runtime): allow OCI device nodes`).
- Container API/CLI commit: `87baba19845e7fb34f936a3f90a35af8af48a573` in `stephenlclarke/container` (`feat(runtime): add device mapping flag`), tracked separately in `docs/upstream/apple-container/PR-device-mappings.md`.
- Compose integration code is tracked in `docs/upstream/container-compose/PR-service-devices.md`.

## Implementation Details

- Added `devices` to `LinuxContainer.Configuration`, defaulting to `[]`.
- Added the same default to the configuration initializer.
- Updated `generateRuntimeSpec()` so configured device nodes are assigned to `spec.linux.devices`.
- Added a focused runtime-spec unit test for a configured character-device node.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter LinuxContainerTests/runtimeSpecIncludesConfiguredDeviceNodes
```

## Compatibility Notes

- Default behavior is unchanged because `devices` defaults to an empty array.
- This does not expose Docker or Compose syntax in `containerization`.
- This does not implement USB, SD-card, PCI, GPU, or arbitrary macOS hardware passthrough; it only projects already-resolved OCI device node metadata into the generated spec.

## Remaining Risks

- Higher layers must still validate Docker-compatible device strings, resolve source devices, and add matching cgroup permission rules.
- The lower runtime still depends on the OCI runtime and VM environment having meaningful device major/minor values for the requested source.
