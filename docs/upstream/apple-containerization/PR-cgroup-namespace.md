# Pull request: allow the sandbox VM cgroup namespace

## Type of Change

- [x] New feature
- [ ] Breaking change
- [x] Documentation and test update

## Motivation and Context

`LinuxContainer` unconditionally created an OCI cgroup namespace. Generic
callers had no way to select the existing sandbox VM cgroup namespace even
though the OCI runtime supports an omitted cgroup namespace entry.

## Changes

- Constructible Containerization commit: `f72625f` (`feat(namespace): add host cgroup namespace`).
- Generic Container consumer: `9dd6cd9` (`feat(runtime): add cgroup namespace option`).
- Compose V2 parity consumer: `1f182f02` (`feat(runtime): map Compose cgroup namespace`).
- Add `LinuxContainer.Configuration.hostCgroupNamespace`, defaulting to `false`.
- Omit only the OCI cgroup namespace when the flag is true; retain the existing
  private namespace behavior for the default.
- Add runtime-spec unit coverage and a macOS-hosted guest integration that
  confirms the selected path starts and exposes a usable cgroup-v2 hierarchy.

## Apple-shaped boundary

This adds one generic OCI namespace-selection primitive in the macOS Linux
guest. It contains no Docker or Compose type, CLI, Windows behavior,
host-Linux path, cgroup parent policy, or host cgroup manipulation.

## Testing

- [x] Focused host `LinuxContainerTests` passed (38 tests).
- [x] Focused macOS-hosted guest integration `container host cgroup namespace`
  passed (1/1), confirming the guest can read its cgroup-v2 membership.
- [x] The Container CLI integration passed against the freshly rebuilt local
  runtime, persisting `hostCgroupNamespace` and reading cgroup v2 in the guest.
- [x] Compose Docker Compose V2 config/dry-run parity passed against Docker
  Compose `5.3.1`; the local Docker daemon was unavailable, so the harness
  intentionally skipped only Engine dry-run confirmation.

## Compatibility and risks

Existing callers receive the unchanged private namespace because the new flag
defaults to false. `host` here means the sandbox VM cgroup namespace: the macOS
runtime gives each sandbox its own Linux VM, so it cannot expose a macOS host
cgroup hierarchy. The patch changes only the presence of the OCI `cgroup`
namespace entry.

## Review checklist

- [ ] Replay `f72625f` on the intended Apple base.
- [ ] Verify an unset flag retains the OCI cgroup namespace.
- [ ] Verify the host flag omits only the OCI cgroup namespace.
- [ ] Keep Docker/Compose types, Windows and host-Linux behavior, cgroup parent
  configuration, and host hierarchy control out of scope.
