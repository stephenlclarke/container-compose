# Pull request: add Linux device mapping runtime data

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This fork-backed change gives `apple/container` a Linux-specific bridge for Docker-compatible `--device` / Compose `devices` behavior. The primitive resolves supported Linux VM device paths to known Linux major/minor metadata, adds OCI `linux.devices` entries, and adds matching cgroup allow rules.

The design follows the existing `LinuxRuntimeData` pattern used by other Linux-only runtime controls:

- CLI parsing happens at the `container run/create` boundary.
- Parsed source, target, and permissions are carried through opaque `RuntimeConfiguration.runtimeData`.
- `RuntimeService.configureContainer` resolves the source device through the runtime-supported Linux VM device table.
- `containerization` generates OCI `linux.devices` and `linux.resources.devices` entries.

References:

- Docker run `--device`: <https://docs.docker.com/reference/cli/docker/container/run/#add-host-device-to-container---device>
- Compose service `devices`: <https://docs.docker.com/reference/compose-file/services/#devices>
- Broader upstream device context: [apple/container#640](https://github.com/apple/container/issues/640), [apple/container#1680](https://github.com/apple/container/issues/1680), [apple/container#1683](https://github.com/apple/container/issues/1683), [apple/container#1511](https://github.com/apple/container/issues/1511), [apple/containerization#74](https://github.com/apple/containerization/issues/74), [apple/containerization#480](https://github.com/apple/containerization/issues/480), and [apple/containerization#569](https://github.com/apple/containerization/pull/569).

## Commit Tracking

- Container code commit: `87baba1ab1bd7bed036e9cb891fd146893c44382` in `stephenlclarke/container` (`feat(runtime): add device mapping flag`).
- Lower runtime code commit: `149a1f5dc9a6d42bef2224cca54bd341bcdd5c6d` in `stephenlclarke/containerization` (`feat(runtime): allow OCI device nodes`).
- Compose mapping code is tracked separately in `docs/upstream/container-compose/PR-service-devices.md`.

## Implementation Details

- Added repeatable `--device` to the management flag group used by `container run` and `container create`.
- Added parser support for Docker-compatible `HOST[:CONTAINER[:PERMISSIONS]]` values.
- Kept Docker CLI compatibility for two-field `HOST:PERMISSIONS` values while Compose-file parity uses normalized source/target/permissions entries.
- Extended `LinuxRuntimeData` with backward-compatible `devices` decoding that defaults old payloads to an empty array.
- Resolve source paths through a known Linux VM device table, rejecting unknown sources before container creation.
- Added OCI `linux.devices` entries and matching `linux.resources.devices` cgroup allow rules.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --filter 'ParserTest/testDevices|ContainerRunCreateCommandTests/.*Device|RuntimeConfigurationTests/.*RuntimeData|RuntimeServiceHostsTests/.*Device'
swift build --product container
git diff --check
```

## Compatibility Notes

- Existing runtime-data payloads remain decodable because missing `devices` defaults to `[]`.
- The default runtime behavior is unchanged when no device mapping is supplied.
- `--device` source paths are resolved through the runtime-supported Linux VM device table. This is Docker-compatible for known VM devices such as `/dev/null` and `/dev/zero`, but it is not USB, SD-card, PCI, GPU, arbitrary macOS hardware passthrough, or arbitrary guest-side device discovery.
- Upstream maintainers may prefer typed API-only configuration and may choose not to expose the Docker-shaped CLI parser directly. The parser exists in the Stephen fork because the current Compose plugin path still uses command vectors for service create/run.

## Remaining Risks

- True host hardware passthrough still needs separate Virtualization/containerization primitives.
- Device source paths outside the supported Linux VM device table will be rejected by the runtime service.
