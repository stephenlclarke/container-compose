# Export never-started container root filesystems

## Summary

- Fall back to the image snapshot recorded in `RuntimeConfiguration` when a never-started container has no bundle rootfs metadata or disk.
- Preserve bundle filesystem metadata and writable `rootfs.ext4` export for containers that have started.
- Surface malformed bundle metadata instead of silently substituting the base image.
- Validate that the selected source is an ext4 block filesystem.
- Add live integration coverage for create-then-export without start.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

`container create` persists enough information to identify the container root filesystem, but `container export` currently assumes runtime startup has already cloned that filesystem into the bundle. Booting a VM solely to make export work is unnecessary and executes image content that callers only intend to inspect.

The fallback is generic. Compose Bridge is the first consumer in this stack: it creates a transformer container, exports the stopped rootfs, and securely selects `/templates` without starting the image.

## Upstream References

- <https://github.com/apple/container/issues/1265>
- <https://github.com/apple/container/pull/1303>
- <https://github.com/docker/compose/blob/main/pkg/bridge/transformers.go>

## Commit Tracking

- Feature implementation: `dd9ca5e` in `stephenlclarke/container` (`feat(export): support never-started containers`).
- Materialized-rootfs selection: `59d49b1` in `stephenlclarke/container` (`fix(export): preserve materialized rootfs selection`).
- Corrupt-metadata guard: `9b43e5b` in `stephenlclarke/container` (`fix(export): reject corrupt bundle metadata`).
- Corrupt-metadata integration coverage: `145b83f` in `stephenlclarke/container` (`test(export): reject corrupt bundle metadata`).
- Archive selection dependency: `5fe7fdc` in `stephenlclarke/containerization`.
- Compose consumer: `docs/upstream/container-compose/PR-compose-bridge-cli.md`.

## Implementation Details

- `ContainersService.exportRootfs` first uses a materialized bundle `rootfs.ext4` when present.
- When bundle `rootfs.json` exists, its filesystem remains authoritative and malformed metadata is returned as an error.
- Only a missing bundle rootfs description falls back to `RuntimeConfiguration`, selecting `rootFsOverride` or the image snapshot filesystem.
- Ext4 block and volume filesystems are exported directly with `EXT4Reader`.
- Other formats return `ContainerizationError.unsupported`.
- No bundle is created, no VM is booted, and the container remains stopped.

## Validation

```bash
make integration CONCURRENT_TEST_SUITES='TestCLIExportCommand/' SERIAL_TEST_SUITES='NoSuchSuite/'
make test
make check
```

The focused integration suite passes both create-then-export and stopped-after-run export. The full unit suite passes 902 Swift Testing cases plus the XCTest suite.

## Compatibility Notes

Existing stopped-container exports continue to read the writable bundle disk and its persisted filesystem metadata. The fallback applies only before bundle rootfs metadata exists and reads the immutable rootfs snapshot already selected at create time.
