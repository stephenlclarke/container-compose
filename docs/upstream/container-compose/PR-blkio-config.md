# Pull Request

## Summary

- Preserve compose-go normalized `blkio_config` fields in the Swift project model.
- Project Compose block I/O weights and throttles into typed OCI block I/O data, with the current command-vector bridge rendering repeatable `container run/create --blkio` arguments matching [apple/container#1595](https://github.com/apple/container/pull/1595).
- Pin the integration branch to `stephenlclarke/containerization@integration/blkio-runtime` through the local `container` stack so the feature can be tested while upstream review continues.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose exposes service-level block I/O controls through `blkio_config`. Chris George's [apple/container#1595](https://github.com/apple/container/pull/1595) proposes the matching `apple/container` runtime contract, with a repeatable `--blkio` flag as its current command-vector surface. Before this change, `container-compose` reduced the field to a boolean and rejected it, so the Compose side could not be tested against the active upstream runtime shape.

This change implements only the plugin-owned half of the feature. Runtime application remains owned by `apple/container` and `apple/containerization`.

References:

- Compose service `blkio_config`: <https://docs.docker.com/reference/compose-file/services/#blkio_config>
- Existing apple/container issue: [apple/container#1512](https://github.com/apple/container/issues/1512)
- Existing apple/container PR: [apple/container#1595](https://github.com/apple/container/pull/1595)
- Required lower-level runtime API: [apple/containerization#739](https://github.com/apple/containerization/pull/739)

## Commit Tracking

- Compose code commit: `ffa2570` (`feat(runtime): map compose blkio config`)
- Container code commits: `cce5438` in `stephenlclarke/container` (`feat(runtime): add blkio runtime data`) and `a41dd78` (`chore(deps): pin containerization fork`)
- Lower runtime code commits: `35b4acb`, `f361c34`, and `dffb914` in `stephenlclarke/containerization`

## Implementation Details

- Replaced the normalizer's boolean `blkioConfig` marker with a structured `normalizedBlkioConfig`.
- Preserved `weight`, `weight_device`, `device_read_bps`, `device_write_bps`, `device_read_iops`, and `device_write_iops`.
- Added Swift `ComposeBlkioConfig`, `ComposeBlkioWeightDevice`, and `ComposeBlkioThrottleDevice` models.
- Added block I/O projection from Compose fields to typed OCI block I/O data.
- Kept `runtimeBlkioArguments(service:)` rendering `--blkio` values in the #1595 CLI format while typed service creation is being wired.
- Validated weights, device paths, and throttle rate strings before runtime commands.
- Updated `PLAN.md` and `STATUS.md`.

## Docker Compose Compatibility Notes

- Supported by this plugin on the integration branch: normalized `blkio_config.weight`.
- Supported by this plugin on the integration branch: `weight_device`.
- Supported by this plugin on the integration branch: read/write bps and iops throttle entries.
- Runtime support remains dependent on [apple/container#1595](https://github.com/apple/container/pull/1595) and the `containerization` blockIO runtime API.
- Non-goal: opening a duplicate apple/container blkio PR while Chris George's PR is active.
- Non-goal: GPU/device passthrough, API-socket exposure, or unrelated resource-control fields.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
cd Tools/compose-normalizer && go test ./...
swift test --filter 'ComposeNormalizerTests/normalizesBlockIOConfigThroughComposeGo|ComposeOrchestratorTests/upMapsBlockIOConfigToRuntimeArguments|ComposeOrchestratorTests/runMapsBlockIOConfigToRuntimeArguments|ComposeOrchestratorTests/runRejectsInvalidBlockIOConfigBeforeRuntimeCommands'
```

Final local checks:

```bash
make check
make coverage-check
git diff --check
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
