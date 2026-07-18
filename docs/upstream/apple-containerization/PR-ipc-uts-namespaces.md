# Pull request: allow sandbox-VM IPC and UTS namespaces

## Type of Change

- [x] New feature
- [ ] Breaking change
- [x] Documentation and test update

## Motivation and Context

`LinuxContainer` unconditionally created OCI IPC and UTS namespaces. Generic
callers could not choose the sandbox VM namespace even though the OCI runtime
supports an omitted IPC or UTS namespace entry.

## Changes

- Constructible Containerization commit: `f842dcf`
  (`feat(namespace): add host IPC and UTS modes`).
- Generic Container consumer: `b63e2af`
  (`feat(runtime): add IPC and UTS namespace options`).
- Compose V2 parity consumer: `3de532af`
  (`feat(runtime): map Compose IPC and UTS namespaces`).
- Add `LinuxContainer.Configuration.hostIPCNamespace` and
  `hostUTSNamespace`, both defaulting to `false`.
- Omit only the matching OCI IPC or UTS namespace when a flag is true; retain
  the existing private namespace behavior by default.
- Add runtime-spec unit coverage and a macOS-hosted guest integration that
  confirms the selected path starts, reports a hostname, and exposes the IPC
  proc surface.

## Apple-shaped boundary

This adds two generic OCI namespace-selection primitives in the macOS Linux
guest. It contains no Docker or Compose type, CLI, Windows behavior, host-Linux
path, cross-container namespace sharing, or macOS host namespace access.

## Testing

- [x] Focused `LinuxContainerTests` passed (39 tests).
- [x] Focused macOS-hosted guest integration `container host IPC and UTS
  namespaces` passed (1/1), confirming the guest starts, has a hostname, and
  can read `/proc/sysvipc/shm`.
- [x] The Container CLI integration passed against the freshly rebuilt local
  runtime, persisting both host-mode choices and checking the same guest
  surfaces.
- [x] Compose Docker Compose V2 config/dry-run parity passed against Docker
  Compose `5.3.1`; the local Docker daemon was unavailable, so the harness
  intentionally skipped only Engine dry-run confirmation.

## Compatibility and risks

Existing callers receive the unchanged private namespaces because both flags
default to false. `host` means the sandbox VM IPC or UTS namespace: each macOS
sandbox has its own Linux VM, so this cannot expose macOS host namespaces. The
patch changes only the presence of the matching OCI namespace entries.

## Review checklist

- [ ] Replay `f842dcf` on the intended Apple base.
- [ ] Verify unset flags retain the OCI IPC and UTS namespaces.
- [ ] Verify each host flag omits only its matching OCI namespace entry.
- [ ] Keep Docker/Compose types, Windows and host-Linux behavior, cross-container
  sharing, and macOS host namespace access out of scope.
