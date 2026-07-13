# Cgroup2Manager Catch Clause Must Match Swift Formatter Spacing

## I Have Done The Following

- [x] Searched existing `apple/containerization` issues and pull requests for `Cgroup2Manager catch where spacing` and `catch  where`.
- [x] Confirmed `swift format lint` requires the doubled-space predicate form in `vminitd/Sources/Cgroup/Cgroup2Manager.swift`.

## Current Behavior

`Cgroup2Manager.processes` must use the exact predicate catch spelling that the repository's strict Swift formatter emits. The one-space form, `catch where isMissingProcessFileError(error)`, fails `swift format lint` even though it has identical runtime behavior.

## Expected Behavior

The catch clause uses the formatter-required spacing:

```swift
catch  where isMissingProcessFileError(error)
```

## Upstream Reference

No matching upstream Apple issue or pull request was found for this formatting cleanup.

## Code Of Conduct

- [x] I agree to follow the project's Code of Conduct.
