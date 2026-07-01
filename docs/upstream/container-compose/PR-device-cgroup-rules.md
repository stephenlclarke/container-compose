# Pull Request

## Summary

- Accept Compose service `device_cgroup_rules` as a supported runtime field.
- Validate rule syntax with the same parser used by the fork-backed `container run/create --device-cgroup-rule` CLI path.
- Render repeatable `--device-cgroup-rule` arguments for `up`, `create`, and one-off `run`.
- Add focused Swift tests and an optional local-only Docker Compose V2 parity target.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose exposes service-level Linux device cgroup rule controls through `device_cgroup_rules`. The field is materially different from host device passthrough: it configures cgroup permissions, while `devices` and `gpus` require runtime device injection. The plugin previously rejected all three together, which blocked a feature that can be implemented through the fork-backed runtime-data path.

References:

- Compose service `device_cgroup_rules`: <https://docs.docker.com/reference/compose-file/services/#device_cgroup_rules>
- Docker run `--device-cgroup-rule`: <https://docs.docker.com/reference/cli/docker/container/run/#device-cgroup-rule>
- Upstream hints reviewed for the broader device area: [apple/container#1683](https://github.com/apple/container/issues/1683), [apple/container#1680](https://github.com/apple/container/issues/1680), [apple/container#1511](https://github.com/apple/container/issues/1511), [apple/container#640](https://github.com/apple/container/issues/640), [apple/containerization#74](https://github.com/apple/containerization/issues/74), [apple/containerization#480](https://github.com/apple/containerization/issues/480), [apple/container#1595](https://github.com/apple/container/pull/1595), [apple/containerization#569](https://github.com/apple/containerization/pull/569), [apple/container#1469](https://github.com/apple/container/discussions/1469), and [apple/container#62](https://github.com/apple/container/discussions/62).

## Commit Tracking

- Lower runtime code commit: `df62b48377b7f2ea0693a02ee4dd0a176756bc2a` in `stephenlclarke/containerization` (`feat(runtime): allow device cgroup rules`).
- Container code commit: `670aa761305135f593e42256579c07fd9722c7d4` in `stephenlclarke/container` (`feat(runtime): add device cgroup rule flag`).
- Compose mapping code is the current `feat(runtime): support device cgroup rules` slice in `stephenlclarke/container-compose`.

## Implementation Details

- Removed `device_cgroup_rules` from the unsupported device-access field group while keeping `credential_spec`, `devices`, and `gpus` blocked at the time of that slice. Service `devices` is now tracked separately in [PR-service-devices.md](PR-service-devices.md).
- Added `runtimeDeviceCgroupRuleArguments(service:)` to validate Compose rule strings through `ContainerAPIClient.Parser.deviceCgroupRules`.
- Added repeatable `--device-cgroup-rule` rendering in the service create/run command path.
- Added pre-side-effect validation so invalid rule strings fail before runtime resources are prepared.
- Verified the automatic container dependency resolver selected the matching Stephen fork commit for package metadata.
- Added `Tools/parity/check-compose-device-cgroup-rules.sh` and `make docker-compose-device-cgroup-rules-parity` as opt-in Docker Compose V2 parity validation.

## Docker Compose Compatibility Notes

Supported on the fork-backed integration stack:

- `compose config --format json` preserves the rule values in the normalized service model; the current renderer uses the internal `deviceCgroupRules` key.
- `compose up`, `compose create`, and one-off `compose run` project the rules to runtime create/run.
- Invalid rule strings are rejected before side effects.

Known remaining device gaps:

- `services.<name>.devices` is supported for the runtime-supported Linux VM device table by the later service-device slice.
- `services.<name>.gpus` remains blocked until GPU passthrough exists.
- Deploy resource device reservations remain blocked because they imply scheduler/device semantics beyond this local runtime mapping.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --filter ComposeOrchestratorTests/upMapsDeviceCgroupRulesToRuntimeArguments
swift test --filter ComposeOrchestratorTests/runMapsDeviceCgroupRulesToRuntimeArguments
swift test --filter ComposeOrchestratorTests/runRejectsInvalidDeviceCgroupRulesBeforeRuntimeCommands
swift test --filter ComposeOrchestratorTests/upRejectsUnsupportedDeviceAccessFieldsBeforeCreatingResources
swift test --filter ComposeOrchestratorTests/runRejectsUnsupportedDeviceAccessFieldsBeforeCreatingResources
```

Optional local Docker Compose V2 parity validation:

```bash
bash -n Tools/parity/check-compose-device-cgroup-rules.sh
shellcheck Tools/parity/check-compose-device-cgroup-rules.sh
make docker-compose-device-cgroup-rules-parity
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
