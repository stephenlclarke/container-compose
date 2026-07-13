# Bug: validate all container bundle identifiers at the storage boundary

<!-- markdownlint-disable MD013 -->

## Bug Details

`ContainersService` stores one bundle per container beneath its managed
container root. Every API route that turns a container identifier into a bundle
path must reject identifiers that are not a single regular filesystem component.

The command-line client already rejects Docker-incompatible entity names, but
direct API and XPC callers can bypass that parser. A server-side boundary is
needed so create, lifecycle, logging, root filesystem export, disk usage,
cleanup, and restored persisted metadata cannot traverse outside the managed
container root.

Requested shape:

- Keep CLI-compatible `Utility.validEntityName` validation for the public
  daemon entry points covered by [apple/container#1735](https://github.com/apple/container/pull/1735).
- Centralize bundle path construction in `ContainersService` with
  `FilePath.Component` validation and reject `.` and `..`.
- Use that helper at every bundle filesystem access, including cleanup and log
  retrieval.
- Ignore invalid persisted identifiers during non-throwing disk accounting and
  reject them when loading the service state.
- Validate volume storage names before deriving their disk-usage path.

## Upstream Search

- [apple/container#1735](https://github.com/apple/container/pull/1735) is the
  preferred open daemon-ID validation change. It covers create, disk usage, and
  root filesystem export, but not every bundle access or persisted metadata.
- No open Apple issue or pull request was found that adds a complete
  `ContainersService` storage-path boundary or validates volume disk usage.
- Do not open a competing PR for the three entry-point checks while #1735 is
  open. This follow-up is only the residual generic storage hardening.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
