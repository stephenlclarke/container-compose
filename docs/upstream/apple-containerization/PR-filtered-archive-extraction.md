# Extract selected archive members

## Summary

- Add `ArchiveReader.extractContents(to:including:)`.
- Skip excluded payloads without materializing them.
- Reuse the existing descriptor-relative secure extraction path for every selected entry.
- Cover selected subtree extraction, symlink preservation, excluded content, and no-match behavior.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Archive consumers sometimes need one subtree from a root filesystem or image archive. The existing API requires extracting every member, which is unnecessarily expensive and encourages callers to build less secure filtering workarounds.

The new overload is generic. Compose Bridge is the first consumer: it combines `apple/container` stopped-rootfs export from `apple/container#1265` and `apple/container#1303` with a `templates` path predicate. No Compose or Docker command policy enters `containerization`.

## Commit Tracking

- Implementation: `5fe7fdc` in `stephenlclarke/containerization` (`feat(archive): extract selected archive members`).
- Rejected-path regression: `405aba3` in `stephenlclarke/containerization` (`test(archive): cover filtered path rejection`).
- Compose consumer: `docs/upstream/container-compose/PR-compose-bridge-cli.md`.

## Implementation Details

- `extractContents(to:)` delegates to the new overload with an always-true predicate.
- Excluded members call `archive_read_data_skip` and propagate skip failures.
- Matching members continue through `FileDescriptorOps` and the existing `openat`/`O_NOFOLLOW` extraction path.
- The return value reports rejected selected paths only.
- No matching entries throws `ArchiveError.failedToExtractArchive`, consistent with an empty archive.

## Testing

```bash
swift test --filter ArchiveReaderTests
make check
```

The focused suite passes 26 tests. Formatting and license checks pass.

## Compatibility Notes

The existing API and extraction behavior are unchanged. The overload is additive and accepts a synchronous path predicate, so callers do not need new model types or archive buffering.
