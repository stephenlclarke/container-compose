# Pull Request

## Summary

- Accept Compose service `devices` as a supported runtime field for the runtime-supported Linux VM device table.
- Validate device mapping syntax before runtime side effects.
- Render repeatable `--device` arguments for `up`, `create`, and one-off `run`.
- Add focused Swift tests and an optional local-only Docker Compose V2 parity target.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose exposes service-level device mappings through `devices`. On Docker Engine, those mappings create device nodes in the container and add matching cgroup permissions. The stephenlclarke fork runtime stack can now represent the known Linux VM device subset by passing Docker-compatible `--device` values to the fork-backed `container` CLI, which resolves supported source devices to Linux major/minor metadata.

This is intentionally narrower than arbitrary macOS hardware passthrough. USB, SD-card, PCI, GPU, and other host hardware passthrough requests still depend on lower-runtime and Virtualization.framework capabilities.

References:

- Compose service `devices`: <https://docs.docker.com/reference/compose-file/services/#devices>
- Docker run `--device`: <https://docs.docker.com/reference/cli/docker/container/run/#add-host-device-to-container---device>
- Upstream hints reviewed: [apple/container#640](https://github.com/apple/container/issues/640), [apple/container#1680](https://github.com/apple/container/issues/1680), [apple/container#1683](https://github.com/apple/container/issues/1683), [apple/container#1511](https://github.com/apple/container/issues/1511), [apple/containerization#74](https://github.com/apple/containerization/issues/74), [apple/containerization#480](https://github.com/apple/containerization/issues/480), [apple/containerization#569](https://github.com/apple/containerization/pull/569), [apple/container#1469](https://github.com/apple/container/discussions/1469), and [apple/container#62](https://github.com/apple/container/discussions/62).

## Commit Tracking

- Lower runtime code commit: `149a1f5dc9a6d42bef2224cca54bd341bcdd5c6d` in `stephenlclarke/containerization` (`feat(runtime): allow OCI device nodes`).
- Container code commit: `87baba1ab1bd7bed036e9cb891fd146893c44382` in `stephenlclarke/container` (`feat(runtime): add device mapping flag`).
- Compose mapping code is the current `feat(devices): support service device mappings` slice in `stephenlclarke/container-compose`.

## Implementation Details

- Removed `devices` from the unsupported device-access field group while keeping `credential_spec` and `gpus` blocked.
- Added `runtimeDeviceArguments(service:)` to normalize string and object device mapping forms.
- Parse Compose device syntax first, then validate the final unambiguous runtime argument with `ContainerAPIClient.Parser.devices`.
- Added repeatable `--device` rendering in the service create/run command path.
- Added pre-side-effect validation so invalid device mappings fail before runtime resources are prepared.
- Added `Tools/parity/check-compose-devices.sh` and `make docker-compose-devices-parity` as opt-in Docker Compose V2 parity validation.

## Docker Compose Compatibility Notes

Supported on the fork-backed integration stack:

- `compose config --format json` preserves device mappings in normalized config.
- `compose up`, `compose create`, and one-off `compose run` project service `devices` to runtime create/run.
- Docker Compose file forms with explicit source, target, and permissions are preserved and mapped.
- Invalid relative targets or invalid permission strings are rejected before side effects.
- Unknown source paths are rejected until the lower runtime exposes guest-side discovery or true host-passthrough primitives.
- Docker Compose can pass relative target strings through Docker Engine in ambiguous short-form cases such as `/dev/null:rw`; this fork-backed CLI bridge rejects those forms so the value is not silently treated as Docker CLI permission shorthand.

Known remaining device gaps:

- `services.<name>.gpus` remains blocked until GPU passthrough exists.
- USB, SD-card, PCI, arbitrary guest-side device discovery, and arbitrary macOS hardware passthrough remain blocked until the lower runtime exposes matching primitives.
- Deploy resource device reservations remain blocked because they imply scheduler/device-resource semantics beyond this local runtime mapping.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --filter 'ComposeOrchestratorTests/.*Devices|ComposeOrchestratorTests/.*DeviceTargets|ComposeOrchestratorTests/.*DeviceObject|ComposeOrchestratorTests/.*DeviceAccess|ComposeOrchestratorTests/.*DeviceCgroup'
make docker-compose-devices-parity
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
