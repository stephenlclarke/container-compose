# Pull Request

## Summary

- Serialize the vmnet-backed macOS integration cases after the normal concurrent test pool drains.
- Retain the existing configurable concurrency for all other integration tests.
- Prevent intermittent Virtualization.framework XPC invalidation during concurrent IPv6 and host-networking VM teardown.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Test infrastructure update

## Motivation and Context

The integration suite can fail an otherwise healthy release gate when concurrent vmnet-backed VM cases stop unexpectedly with `VZErrorDomain Code=1`. The failing IPv6 case succeeds repeatedly when run serially, showing host VM lifecycle contention rather than a functional IPv6 regression.

No matching open Apple issue or pull request was found after reviewing current `apple/containerization` vmnet, IPv6, and integration work.

## Implementation Details

- Adds a typed `requiresExclusiveExecution` marker to integration jobs.
- Marks only macOS 26 vmnet-backed container and pod networking cases as exclusive.
- Executes ordinary jobs through the existing bounded task group.
- Executes exclusive jobs sequentially after that group completes.
- Preserves the runner's logging, skip handling, error reporting, and final accounting.

## Compatibility Notes

- This change affects test scheduling only.
- Linux container runtime APIs and behavior are unchanged.
- Docker Compose validation and policy remain in `container-compose`.

## Commit Tracking

- Fork commit: [`c3f8fe66d52c3509863ebbb439338d6dbe3284e0`](https://github.com/stephenlclarke/containerization/commit/c3f8fe66d52c3509863ebbb439338d6dbe3284e0) (`fix(integration): serialize vmnet integration tests`).

## Validation

```sh
make check
make containerization integration
```

The signed macOS integration executable completed all 166 tests. The eleven vmnet and IPv6 cases ran one at a time after the regular concurrent set.

## Checklist

- [x] Reviewed current upstream IPv6, vmnet, and integration issues and pull requests.
- [x] Added focused scheduling coverage through the full signed runtime suite.
- [x] Kept the change Apple-native and outside Docker Compose policy.
- [x] Avoided pushing changes to Apple remotes.
