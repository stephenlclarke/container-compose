# Pull request: add generic IPC and UTS namespace selection

> [!IMPORTANT]
> Sign and verify all commits before opening the upstream pull request. File the
> linked feature request before proposing this feature.

## Type of Change

- [x] New feature
- [ ] Breaking change
- [x] Documentation and test update

## Motivation and Context

The lower runtime can omit OCI IPC and UTS namespaces to select the sandbox VM
namespaces, but Container had no generic request/configuration bridge for either
choice.

## Changes

- Constructible Container commit: `b63e2af`
  (`feat(runtime): add IPC and UTS namespace options`).
- Required lower-runtime implementation: `f842dcf` in `apple/containerization`
  (`feat(namespace): add host IPC and UTS modes`).
- Separate Compose V2 parity consumer: `3de532af`
  (`feat(runtime): map Compose IPC and UTS namespaces`).
- Add backward-compatible `ContainerConfiguration.hostIPCNamespace` and
  `hostUTSNamespace`; older persisted configurations decode as private (`false`).
- Add `container run|create --ipc <host|private>` and
  `--uts <host|private>`, rejecting other values at the generic CLI boundary.
- Forward both values to `LinuxContainer.Configuration` and cover parsing,
  configuration encoding, help, command vectors, and a guest-visible CLI
  integration.

## Apple-shaped boundary

This is a minimal generic Container configuration and OCI projection. No
Compose or Docker model enters Container source. It adds no Windows behavior,
host-Linux path, IPC sharing between containers, or macOS host namespace access.

## Testing

- [x] Focused configuration/parser/command tests passed (271 tests).
- [x] `container run --help` exposes `--ipc <ipc>` and `--uts <uts>` with
  accurate `host or private` mode descriptions.
- [x] The local runtime CLI integration passed after rebuilding the daemon,
  persisting both host-mode flags and confirming a hostname plus the IPC proc
  surface inside the guest.
- [x] Compose Docker Compose V2 config/dry-run parity passed against Docker
  Compose `5.3.1`; no Docker daemon was available, so the harness skipped only
  Engine dry-run confirmation.

## Compatibility and risks

Absent and `private` values preserve existing behavior. `host` selects the
sandbox VM IPC or UTS namespace, not a macOS host namespace. The parser rejects
unknown values rather than silently selecting a namespace mode.

## Review checklist

- [ ] Replay `f842dcf`, then `b63e2af` on the intended Apple branches.
- [ ] Verify `container run --help` includes the generic `--ipc` and `--uts`
  options.
- [ ] Verify `private` and omission retain both OCI namespaces; verify each
  `host` mode omits the matching entry in the generated runtime spec.
- [ ] Keep Docker/Compose types, Windows and host-Linux behavior, inter-container
  IPC sharing, and macOS host namespace access out of scope.
