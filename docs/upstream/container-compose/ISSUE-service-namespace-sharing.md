# Compatibility gap: Compose service/container namespace sharing

## Summary

Docker Compose accepts `pid: service:NAME`, `pid: container:ID`,
`ipc: shareable`, `ipc: service:NAME`, and `ipc: container:ID`. Those values
must remain pre-side-effect errors in container-compose until the Apple runtime
stack provides a durable multi-container sandbox primitive.

The macOS Linux guest can share selected PID and IPC namespaces:
Containerization's `LinuxPod.Configuration.NamespaceSharing` passed focused
macOS integration tests for both. That experimental lower-level path is
intentionally not used by Compose because the current Container runtime starts
one VM per persisted container and the pod API has no per-container
network-namespace attachment lifecycle. Mapping a Compose sharing field to it
would silently share guest networking as well, violating Docker semantics.

## Required runtime work

1. Containerization: durable multi-workload sandbox with typed PID/IPC sharing
   and distinct guest network attachments. See
   [ISSUE-shared-sandbox-namespaces.md](../apple-containerization/ISSUE-shared-sandbox-namespaces.md).
2. Container: persisted generic sandbox membership, grouped lifecycle/recovery,
   and an Apple-shaped typed namespace-sharing API. See
   [ISSUE-shared-sandbox-namespaces.md](../apple-container/ISSUE-shared-sandbox-namespaces.md).
3. Compose: resolve `service:` targets in the selected project, reject cycles
   and incompatible membership before side effects, map only the standard
   Compose values to the generic runtime API, and preserve the existing
   `host`/`private` behavior.

## Required parity validation once runtime support exists

- Unit tests for target resolution, cycle detection, invalid targets, and
  renderer arguments.
- Docker Compose V2 YAML config parity for each accepted PID and IPC spelling.
- A macOS guest integration stack where a joining workload can see a target
  process (PID) or shared IPC object (IPC) while its network identity remains
  distinct unless `network_mode` independently requests sharing.
- Regression tests that plain `pid: private` and `ipc: private` retain current
  single-container behavior.

## Current behavior

The Compose normalizer accepts Docker Compose V2's configuration surface but
the runtime preflight rejects these sharing values before creating a network,
volume, or container. This is truthful partial parity rather than a no-op.
