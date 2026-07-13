# Pull Request: Restore Cgroup2Manager Swift Formatter Catch Spacing

## Summary

Restore the missing-process catch clause in `Cgroup2Manager.processes` to the `catch  where` spelling emitted by the repository's strict Swift formatter.

## Motivation

The one-space predicate form fails the repository's strict Swift formatter. Restoring the formatter-required form is intentionally tiny: it does not change process enumeration behavior, Linux-only test coverage, package products, or public API.

## Changes

- Update `vminitd/Sources/Cgroup/Cgroup2Manager.swift` so the missing-process catch clause uses the formatter-required spacing.
- Leave all Cgroup process parsing and error handling behavior unchanged.

## Upstream Reference

- No matching upstream Apple issue or pull request was found for `Cgroup2Manager catch where spacing` or `catch  where`.
- Matching issue handoff: `docs/upstream/apple-containerization/ISSUE-cgroup-catch-format.md`.

## Commit Tracking

- Fork: `stephenlclarke/containerization`
- Branch: `main`
- Commit: `6dc0c7be42687a9cf0d07eee1ba9cf2a1abf510c`

## Validation

```sh
swift format lint --configuration .swift-format-nolint vminitd/Sources/Cgroup/Cgroup2Manager.swift
swift build --disable-automatic-resolution --target Cgroup
git diff --check
```

Results:

- Strict Swift formatting and the `Cgroup` target build successfully.
- The committed diff has no whitespace errors.
- `Cgroup2ManagerProcessTests` are Linux-only and are not available on this macOS validation host.

## Compatibility And Risk

This is a formatting-only change. It does not alter runtime behavior, public API, generated artifacts, or supported platforms.

## Release Note Highlight

- None; formatting-only Apple handoff cleanup.

## Remaining Risk

None identified.
