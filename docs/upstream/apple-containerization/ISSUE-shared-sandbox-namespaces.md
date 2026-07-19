# Feature request: durable shared-sandbox namespace lifecycle

## Feature or enhancement request details

`LinuxPod` already demonstrates that a macOS-hosted Linux guest can run several
OCI workloads in one VM and join selected PID and IPC namespaces to a pause
process. The focused macOS integration tests `pod shared PID namespace` and
`pod shared IPC namespace` prove respectively that a second workload can see a
first workload's live process and shares the same IPC namespace identifier.

That experimental API is not yet a Container runtime primitive. It configures a
single VM-level interface collection and does not provide a persistent
per-container network-namespace attachment lifecycle. Replacing independent
`LinuxContainer` instances with a pod for a PID-only request would therefore
silently put the workloads into one guest network context, which is not Docker
or Compose semantics.

Request a generic, durable multi-container sandbox primitive that can retain
individually addressable workloads while selectively sharing Linux namespaces.
The API must remain independent of Docker and Compose terminology.

Required lower-runtime properties:

- create, recover, and stop a sandbox with multiple named workload root filesystems;
- retain each workload's OCI process, mounts, cgroup, logs, and lifecycle state;
- attach guest network interfaces to each workload without widening another
  workload's network visibility;
- expose an explicit, typed shared-namespace policy, initially for PID and IPC;
- keep private namespaces and the existing single-container `LinuxContainer`
  behavior as the default;
- reject joining a namespace outside the same sandbox instead of accepting a
  host path or an opaque OCI namespace path.

The future Container layer owns generic persisted sandbox membership and CLI/API
configuration. The Compose layer owns Docker-shaped `pid` and `ipc` parsing.

## Evidence

- Fork commit `89aa0eb6fb451875b73e4f4322a735b740e3cc2a`
  (`feat(pod): add typed shared namespace policy`) adds
  `LinuxPod.Configuration.NamespaceSharing` with PID and IPC selections.
- `Sources/Containerization/LinuxPod.swift` starts a pause process and joins
  each selected workload namespace through `/proc/<pause-pid>/ns/pid` or
  `/proc/<pause-pid>/ns/ipc`.
- `Sources/Integration/PodTests.swift` contains the passing macOS guest tests
  `testPodSharedPIDNamespace` and `testPodSharedIPCNamespace`.
- The current pod-generated OCI namespace list contains cgroup, IPC, mount,
  UTS, and PID entries but no per-workload network namespace or interface
  lifecycle. This makes the existing API unsuitable as a transparent
  Compose service/container namespace compatibility adapter.

## Scope exclusions

- Docker/Compose strings, Windows behavior, macOS-host namespaces, host-Linux
  paths, and arbitrary namespace-path joins.
- A Compose adapter until the generic Container runtime consumes the completed
  lower-runtime primitive.

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
