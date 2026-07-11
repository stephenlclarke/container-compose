# Pull Request: Preserve The Serial Integration Rootfs On macOS

## Summary

Resolve symlinks for both the active rootfs and directory entries before the
serial cleanup comparison. This treats `/var` and `/private/var` as the same
filesystem location without weakening cleanup of prior per-test artifacts.

## Upstream Reference

- Follow-up to merged
  [apple/containerization#782](https://github.com/apple/containerization/pull/782).
- No matching open issue or pull request was found.

## Commit Tracking

- Fork commit: `2e38f8e` in `stephenlclarke/containerization`.

## Validation

```sh
./bin/containerization-integration --kernel ./bin/vmlinux-arm64 \
  --max-concurrency 1 --filter 'container copy out'
make integration
```
