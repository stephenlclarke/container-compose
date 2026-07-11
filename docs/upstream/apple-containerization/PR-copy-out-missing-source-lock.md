# Pull Request: Release Copy-Out State After Guest Failure

## Summary

- Finish the metadata stream and vsock listener when guest copy-out fails.
- Keep outer cleanup idempotent for successful and failed transfers.
- Prove that a missing source does not block a later exec on the container.

## Upstream Reference

- Bug: [apple/container#1927](https://github.com/apple/container/issues/1927)
- No overlapping `apple/containerization` pull request was found.

## Commit Tracking

- Fork commit: `b065eaa` in `stephenlclarke/containerization`.
- The commit is intentionally separate from other local fixes.

## Validation

```sh
swift test --disable-automatic-resolution --filter LinuxContainerTests
./bin/containerization-integration --kernel ./bin/vmlinux-arm64 \
  --max-concurrency 1 --filter 'container copy out'
make check
make test
```

The focused VM filter covers normal file copy, missing-source recovery, and
directory copy. The missing-source case runs a subsequent exec to verify that
the state lock was released.
