# Add a private guest user-namespace primitive

## Problem

`LinuxContainer` could create private PID, mount, IPC, UTS, and cgroup
namespaces but not a usable OCI user namespace. A user namespace needs its
UID/GID maps written by a process in the parent namespace, and guest rootfs
mounts must finish before that namespace loses the required capabilities.

## Requested behavior

- Add an opt-in, default-false `privateUserNamespace` configuration property.
- Project an OCI `user` namespace with identity UID/GID maps:
  `0 0 4294967295`.
- Synchronize guest map creation with a parent-namespace mapper before
  workload credentials and capabilities are applied.
- Join the target user and IPC namespaces during `exec`.

## Out of scope

Custom mapping ranges, host-Linux behavior, macOS user namespaces, Windows,
Docker/Compose parsing, and cross-container user-namespace sharing.

## Acceptance criteria

- The default OCI spec is unchanged.
- A private configuration has a user namespace and matching UID/GID maps.
- A macOS-hosted guest starts, supports a later `exec`, and reports the
  identity map from `/proc/self/{uid,gid}_map`.
