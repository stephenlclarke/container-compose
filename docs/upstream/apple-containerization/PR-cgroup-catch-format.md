# Pull Request: Normalize Cgroup2Manager Catch Clause Spacing

## Summary

Normalize the missing-process catch clause in `Cgroup2Manager.processes` from `catch  where` to `catch where`.

## Motivation

The current spacing is visually inconsistent with Swift style and was identified during the stack critical review. The cleanup is intentionally tiny: it does not change process enumeration behavior, Linux-only test coverage, package products, or public API.

## Changes

- Update `vminitd/Sources/Cgroup/Cgroup2Manager.swift` so the missing-process catch clause uses standard Swift spacing.
- Leave all Cgroup process parsing and error handling behavior unchanged.

## Upstream Reference

- No matching upstream Apple issue or pull request was found for `Cgroup2Manager catch where spacing` or `catch  where`.
- Matching issue handoff: `docs/upstream/apple-containerization/ISSUE-cgroup-catch-format.md`.

## Commit Tracking

- Fork: `stephenlclarke/containerization`
- Branch: `main`
- Commit: `03f8a105813ae680757f4f456a53130c11c0bf66`

## Validation

```sh
swift build --disable-automatic-resolution --target Cgroup
git diff --check
```

Results:

- The `Cgroup` target builds successfully.
- The committed diff has no whitespace errors.
- `Cgroup2ManagerProcessTests` are Linux-only and are not available on this macOS validation host.

## Compatibility And Risk

This is a formatting-only change. It does not alter runtime behavior, public API, generated artifacts, or supported platforms.

## Release Note Highlight

- None; formatting-only Apple handoff cleanup.

## Remaining Risk

None identified.
