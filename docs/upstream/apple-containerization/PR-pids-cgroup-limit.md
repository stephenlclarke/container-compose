# Pull request: add Linux pids cgroup limit configuration

## Summary

- Add optional `pidsLimit` to `LinuxContainer.Configuration`.
- Project configured values into OCI `LinuxResources.pids`.
- Add focused spec-generation coverage.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker exposes a pids cgroup limit through `docker run --pids-limit`, and Docker Compose exposes the same intent through service `pids_limit`. The lower `containerization` package already had the OCI `LinuxPids` type, but there was no public `LinuxContainer.Configuration` field to carry the value into generated specs.

## Commit Tracking

- Lower runtime code commit: `a51832f51b57cd0209b4926f098987d5e8980051` in `stephenlclarke/containerization` (`feat(runtime): add pids cgroup limit`).
- Container CLI/API bridge commit: `b9207d9131f34901bc2ca6ca4b847f7da29d5a0b` in `stephenlclarke/container` (`feat(runtime): add pids limit flag`).
- Compose mapping code is the current `container-compose` pids-limit parity slice.

## Implementation Details

- Added `public var pidsLimit: Int64?` to `LinuxContainer.Configuration`.
- Added `pidsLimit` to the memberwise initializer with a default of `nil`.
- Set `LinuxResources(pids:)` when `pidsLimit` is present.
- Left validation to higher layers because Docker-compatible accepted values are CLI/API policy, not a generic OCI model rule.

## Testing

Focused validation:

```bash
swift test --filter runtimeSpecIncludesConfiguredPidsLimit
```

## Compatibility Notes

The field is optional and defaults to `nil`, so existing callers keep their current behavior. The generated OCI spec only changes when a caller explicitly sets the value.
