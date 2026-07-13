# Cgroup2Manager Has A Nonstandard Catch Clause Spacing

## I Have Done The Following

- [x] Searched existing `apple/containerization` issues and pull requests for `Cgroup2Manager catch where spacing` and `catch  where`.
- [x] Confirmed the local fork had the doubled-space `catch  where` form in `vminitd/Sources/Cgroup/Cgroup2Manager.swift`.

## Current Behavior

`Cgroup2Manager.processes` contains a missing-process recovery clause written as `catch  where isMissingProcessFileError(error)`. The code behaves correctly, but the doubled spacing is nonstandard Swift style and was called out during review.

## Expected Behavior

The catch clause uses normal Swift spacing:

```swift
catch where isMissingProcessFileError(error)
```

## Upstream Reference

No matching upstream Apple issue or pull request was found for this formatting cleanup.

## Code Of Conduct

- [x] I agree to follow the project's Code of Conduct.
