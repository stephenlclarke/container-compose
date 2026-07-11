# Pull request: add pids limit flag

## Summary

- Add `--pids-limit` to `container run` and `container create`.
- Carry the value through Linux runtime data.
- Apply the decoded value to `LinuxContainer.Configuration.pidsLimit`.
- Add parser, command, and runtime-data compatibility tests.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker exposes a process-count cgroup limit through `docker run --pids-limit`. Compose service `pids_limit` should be able to use the same runtime primitive through the fork-backed command-vector path. The lower runtime already has an OCI projection for pids limits via `containerization@a51832f`.

## Commit Tracking

- Container code commit: `b9207d9131f34901bc2ca6ca4b847f7da29d5a0b` in `stephenlclarke/container` (`feat(runtime): add pids limit flag`).
- Lower runtime code commit: `a51832f51b57cd0209b4926f098987d5e8980051` in `stephenlclarke/containerization` (`feat(runtime): add pids cgroup limit`).
- Compose mapping code is tracked separately in `docs/upstream/container-compose/PR-pids-limit.md`.

## Implementation Details

- Added `pidsLimit` to the management flag group shared by `container run` and `container create`.
- Used unconditional single-value parsing so `--pids-limit -1` works without requiring `--pids-limit=-1`.
- Added `Parser.pidsLimit(_:)` validation for `-1` or positive values.
- Extended `LinuxRuntimeData` with optional `pidsLimit` and backward-compatible decoding.
- Applied decoded values in `RuntimeService.configureContainer`.
- Updated `Package.resolved` to the matching stephenlclarke `containerization` revision.

## Testing

Focused validation:

```bash
swift test --filter 'testPidsLimit|PidsLimit|RuntimeConfigurationTests|ContainerRunCreateCommandTests'
```

## Compatibility Notes

Existing runtime-data payloads remain decodable because missing `pidsLimit` defaults to `nil`. The default runtime behavior is unchanged when no pids limit is supplied.

## Remaining Risks

This adds the local Docker-compatible CLI/API bridge only. Deploy resource reservations and scheduler-level semantics remain separate higher-level concerns.
