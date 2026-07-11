# Serial Integration Cleanup Deletes The Active Rootfs On macOS

## Upstream Reference

- Introduced with the Linux integration harness in merged
  [apple/containerization#782](https://github.com/apple/containerization/pull/782).
- No matching open issue or pull request was found.

## Problem

The serial integration path preserves the active unpacked rootfs by comparing
absolute path strings. macOS can create a temporary URL under `/var` and return
the same directory entry under `/private/var`. The strings differ, so cleanup
deletes the active rootfs before it is cloned for the test.

## Expected Behavior

Resolve filesystem aliases before comparing cleanup candidates. Serial and
parallel integration runs must use the same rootfs successfully.
