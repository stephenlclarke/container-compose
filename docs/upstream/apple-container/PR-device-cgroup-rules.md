# Pull request: add Linux device cgroup rule runtime data

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This fork-backed change gives `apple/container` a Linux-specific bridge for OCI device cgroup rules. It is needed by higher-level tooling that wants Docker-compatible `--device-cgroup-rule` / Compose `device_cgroup_rules` behavior, but the Apple-facing primitive itself is not Compose-specific and does not implement host-device passthrough.

The design follows the existing `LinuxRuntimeData` pattern used by other Linux-only runtime controls:

- CLI parsing happens at the `container run/create` boundary.
- The parsed rules are carried through opaque `RuntimeConfiguration.runtimeData`.
- `RuntimeService.configureContainer` applies them to `LinuxContainer.Configuration.deviceCgroupRules`.
- `containerization` generates OCI `linux.resources.devices` entries.

References:

- Docker run `--device-cgroup-rule`: <https://docs.docker.com/reference/cli/docker/container/run/#device-cgroup-rule>
- Compose service `device_cgroup_rules`: <https://docs.docker.com/reference/compose-file/services/#device_cgroup_rules>
- Broader upstream device context: [apple/container#1683](https://github.com/apple/container/issues/1683), [apple/container#1680](https://github.com/apple/container/issues/1680), [apple/container#1511](https://github.com/apple/container/issues/1511), [apple/container#640](https://github.com/apple/container/issues/640), [apple/containerization#74](https://github.com/apple/containerization/issues/74), [apple/containerization#480](https://github.com/apple/containerization/issues/480), and [apple/containerization#569](https://github.com/apple/containerization/pull/569).

## Commit Tracking

- Container code commit: `670aa761305135f593e42256579c07fd9722c7d4` in `stephenlclarke/container` (`feat(runtime): add device cgroup rule flag`).
- Lower runtime code commit: `df62b48377b7f2ea0693a02ee4dd0a176756bc2a` in `stephenlclarke/containerization` (`feat(runtime): allow device cgroup rules`).
- Compose mapping code is tracked separately in `docs/upstream/container-compose/PR-device-cgroup-rules.md`.

## Implementation Details

- Added repeatable `--device-cgroup-rule` to the management flag group used by `container run` and `container create`.
- Added parser support for Docker-compatible rule strings in `<type> <major>:<minor> <access>` form.
- Accepted device types `a`, `b`, and `c`.
- Accepted `*` or non-negative integers for major/minor values.
- Accepted access strings containing only `r`, `w`, and `m`.
- Extended `LinuxRuntimeData` with backward-compatible `deviceCgroupRules` decoding that defaults old payloads to an empty array.
- Passed decoded rules to `LinuxContainer.Configuration.deviceCgroupRules`.
- Pinned the local package to the matching `stephenlclarke/containerization` commit.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --filter ParserTest/testDeviceCgroupRules
swift test --filter ContainerRunCreateCommandTests
swift test --filter RuntimeConfigurationTests
swift build --product container
git diff --check
```

## Compatibility Notes

- Existing runtime-data payloads remain decodable because missing `deviceCgroupRules` defaults to `[]`.
- The default runtime behavior is unchanged when no rule is supplied.
- This does not implement Docker `--device`, Compose `devices`, GPU passthrough, USB sharing, or SD-card passthrough.
- Upstream maintainers may prefer typed API-only configuration and may choose not to expose the Docker-shaped CLI parser directly. The parser exists in the Stephen fork because the current Compose plugin path still uses command vectors for service create/run.

## Remaining Risks

- The runtime applies cgroup rules only; it does not guarantee the referenced device node exists inside the container.
- Host-device and GPU passthrough still need separate Virtualization/containerization primitives.
