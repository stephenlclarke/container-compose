# Pull Request

## Summary

- Accept Compose service `pids_limit` as a supported runtime field.
- Render positive `pids_limit` values as `--pids-limit` for `up`, `create`, and one-off `run`.
- Preserve Docker Compose local behavior by omitting the runtime flag for non-positive values.
- Add focused Swift tests and Docker Compose parity coverage.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose exposes service-level process-count cgroup control through `pids_limit`. The plugin already preserved the normalized value but rejected it before resource creation. The fork-backed runtime stack now has the required Apple-shaped primitive:

- `containerization@a51832f` adds optional `LinuxContainer.Configuration.pidsLimit`.
- `container@b9207d9` adds `container run/create --pids-limit`.

This lets `container-compose` support the Compose field without inventing Compose-specific runtime behavior.

## Commit Tracking

- Lower runtime code commit: `a51832f51b57cd0209b4926f098987d5e8980051` in `stephenlclarke/containerization` (`feat(runtime): add pids cgroup limit`).
- Container code commit: `b9207d9131f34901bc2ca6ca4b847f7da29d5a0b` in `stephenlclarke/container` (`feat(runtime): add pids limit flag`).
- Compose mapping code is the current `feat(runtime): support service pids limits` slice in `stephenlclarke/container-compose`.

## Implementation Details

- Removed `pids_limit` from the unsupported memory/OOM/process field group.
- Added `runtimePidsLimitArgument(service:)` to project positive values and leave non-positive values unset.
- Rendered `--pids-limit` in service create/run command vectors.
- Added `Tools/parity/check-compose-pids-limit.sh` and `make docker-compose-pids-limit-parity`.
- Updated README, STATUS, and parity docs.

## Docker Compose Compatibility Notes

Supported on the fork-backed integration stack:

- `compose config --format json` preserves the normalized `pidsLimit`.
- `compose up`, `compose create`, and one-off `compose run` project the limit to runtime create/run.
- `pids_limit: -1`, `0`, and other non-positive values leave the local runtime flag unset, matching Docker Compose's local Engine behavior.

Deploy pids/device/generic resource reservations remain separate scheduler/runtime gaps and are not covered by this service-field mapping.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --disable-automatic-resolution --filter 'upMapsPidsLimitToRuntimeArguments|upOmitsUnlimitedPidsLimitFromRuntimeArguments|runMapsPidsLimitToRuntimeArguments|runOmitsNonPositivePidsLimitFromRuntimeArguments'
bash -n Tools/parity/check-compose-pids-limit.sh
make docker-compose-pids-limit-parity
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
