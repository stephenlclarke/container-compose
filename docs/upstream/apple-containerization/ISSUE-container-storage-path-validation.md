# Bug: validate container manager identifiers before storage access

<!-- markdownlint-disable MD013 -->

## Bug Details

`ContainerManager` derives a container directory from the caller-provided
container identifier. Its create, boot-log, network-release, and delete paths
must require one regular filesystem component before touching managed state.

Without that validation, a caller that reaches the library API directly can
provide a nested, absolute, current-directory, or parent-directory identifier.
The manager must reject it before any network or filesystem operation.

Requested shape:

- Add one `FilePath.Component`-based path helper for the managed container
  root.
- Reject empty identifiers and `.` / `..` in addition to paths with separators.
- Use the helper before creating container state, creating the boot-log path,
  releasing network state, and deleting the bundle.
- Keep CLI and Docker/Compose option parsing outside `containerization`.

## Upstream Search

- No open Apple issue or pull request was found that validates
  `ContainerManager` container identifiers at this library boundary.
- [apple/containerization#796](https://github.com/apple/containerization/pull/796)
  validates bridge interface names and is related input-hardening work, but it
  does not cover container storage identifiers.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
