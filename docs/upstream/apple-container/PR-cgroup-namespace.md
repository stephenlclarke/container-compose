# Pull request: add generic cgroup namespace selection

> [!IMPORTANT]
> Sign and verify all commits before opening the upstream pull request. File the
> linked feature request before proposing this feature.

## Type of Change

- [x] New feature
- [ ] Breaking change
- [x] Documentation and test update

## Motivation and Context

The lower runtime can omit an OCI cgroup namespace to select the sandbox VM's
cgroup namespace, but Container had no generic request/configuration bridge for
that choice.

## Changes

- Constructible Container commit: `9dd6cd9` (`feat(runtime): add cgroup namespace option`).
- Required lower-runtime implementation: `f72625f` in `apple/containerization`
  (`feat(namespace): add host cgroup namespace`).
- Separate Compose V2 parity consumer: `1f182f02`
  (`feat(runtime): map Compose cgroup namespace`).
- Add backward-compatible `ContainerConfiguration.hostCgroupNamespace`; older
  persisted configurations decode as private (`false`).
- Add `container run|create --cgroupns <host|private>` and reject other values
  at the generic CLI boundary.
- Forward the result to `LinuxContainer.Configuration.hostCgroupNamespace` and
  cover parsing, configuration encoding, help, command vectors, and a
  guest-visible CLI integration.

## Apple-shaped boundary

This is a minimal generic Container configuration and OCI projection. No
Compose or Docker model enters Container source. It adds no Windows behavior,
host-Linux path, cgroup parent setting, or macOS host cgroup control.

## Testing

- [x] Focused configuration/parser/command tests passed (266 tests).
- [x] `container run --help` exposes `--cgroupns <cgroupns>` with the accurate
  `host or private` mode description.
- [x] The local runtime CLI integration passed after rebuilding the daemon,
  persisting `hostCgroupNamespace == true` and confirming guest cgroup-v2 use.
- [x] Compose Docker Compose V2 config/dry-run parity passed against Docker
  Compose `5.3.1`; no Docker daemon was available, so the harness skipped only
  Engine dry-run confirmation.

## Compatibility and risks

Absent and `private` values preserve existing behavior. `host` selects the
sandbox VM cgroup namespace, not a macOS host hierarchy. The parser rejects
unknown values rather than silently selecting a namespace mode.

## Review checklist

- [ ] Replay `f72625f`, then `9dd6cd9` on the intended Apple branches.
- [ ] Verify `container run --help` includes the generic `--cgroupns` option.
- [ ] Verify `private` and omission retain the OCI cgroup namespace; verify
  `host` omits it in the generated runtime spec.
- [ ] Keep Docker/Compose types, Windows and host-Linux behavior, cgroup parent
  configuration, and macOS host hierarchy control out of scope.
