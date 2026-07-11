# Pull Request: Verify Launchd Startup Identity

## Summary

- Surface nonzero `launchctl bootstrap` status.
- Skip bootstrap when the API service label is already registered.
- Compare the health response's canonical app root with the requested path.
- Cover status validation and matching/mismatched app roots without invoking
  launchd in unit tests.

## Upstream Reference

- Fixes [apple/container#1757](https://github.com/apple/container/issues/1757).
- No overlapping open pull request was found.

## Commit Tracking

- Fork commit: `6ac1253` in `stephenlclarke/container`.
- The commit is intentionally separate from imported upstream changes.

## Validation

```sh
swift test --disable-automatic-resolution \
  --filter 'ServiceManagerTests|SystemStartTests'
make check
make test
```
