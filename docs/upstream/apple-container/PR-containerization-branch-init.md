<!-- markdownlint-disable MD013 -->

# fix(build): skip immutable dependency checkout init builds

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

SwiftPM returns `version: "unspecified"` for a branch dependency as well as a local edit. `install-init.sh` treated both as editable and attempted to build inside SwiftPM's read-only source-control checkout, so a full integration run failed before executing tests.

## Implementation Details

- Keep the existing `unspecified` check as the edit-mode signal.
- Require the resolved package's `Package.swift` to be writable before building a custom init image.
- Exit successfully with a clear message for immutable source-control checkouts.
- Quote the resolved dependency path and `cctl` executable.

## Commit Tracking

- Implementation: `3d9ade4` in `stephenlclarke/container` (`fix(build): skip immutable dependency checkout init builds`).
- Lower runtime code: not required.

## Testing

```bash
shellcheck scripts/install-init.sh
scripts/install-init.sh --disable-kernel-install
make check
make integration
```

The full integration run completed with 214 concurrent tests and 142 serial tests passing.

## Compatibility Notes

Writable local edits retain the custom init-image workflow. Released and branch-pinned source-control dependencies no longer trigger an invalid nested build.
