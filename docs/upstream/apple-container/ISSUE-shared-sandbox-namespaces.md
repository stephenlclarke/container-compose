# Feature request: generic shared sandbox membership and namespaces

## Feature or enhancement request details

The Container runtime persists and serves one `LinuxContainer` in each
`RuntimeService`, so every user container owns a VM. This is correct for the
default isolation model but makes `pid: service:NAME`, `pid: container:ID`, and
the equivalent IPC forms impossible to implement by passing a namespace path
between existing services: the target workload is in another VM.

Containerization has an experimental in-VM pod implementation for typed PID
and IPC sharing, but it cannot be substituted directly because the production
runtime has no durable multi-container sandbox record, no grouped
recovery/stop lifecycle, and no per-workload network attachment contract. A
generic Container primitive is needed before a higher-level client can request
selected namespace sharing without changing unrelated isolation.

Requested Apple-shaped surface:

- persist a generic sandbox identifier and member relationship separately from
  Docker or Compose concepts;
- group member create/start/stop/recovery through one runtime service and one
  underlying guest VM;
- select only typed shared namespace classes supported by the completed lower
  runtime, initially PID and IPC;
- preserve separate container identities, filesystems, resources, logs,
  attached networks, and lifecycle operations;
- reject a request whose target is absent, not in the same sandbox, or has an
  incompatible sharing policy before side effects.

The user-facing CLI should expose generic sandbox and namespace-sharing terms;
Container Compose will be the only layer that maps Docker Compose
`service:`/`container:` spelling to that API.

## Evidence

- `Sources/Services/RuntimeLinux/Server/RuntimeService.swift` has one
  `ContainerInfo` and constructs one `LinuxContainer` per service process.
- `LinuxPod.Configuration.NamespaceSharing` passes lower-runtime macOS guest
  tests for both PID and IPC sharing, but it is not represented in the
  Container persistence or service API.
- See the lower-runtime handoff
  [ISSUE-shared-sandbox-namespaces.md](../apple-containerization/ISSUE-shared-sandbox-namespaces.md).

## Scope exclusions

- Docker or Compose data models in Container sources.
- Windows, macOS-host namespace access, arbitrary OCI namespace paths, and
  Docker host-device privilege behavior.

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
