# Feature request: expose sandbox-VM IPC and UTS namespace selection

## Feature or enhancement request details

`LinuxContainer` always added OCI IPC and UTS namespaces, leaving no generic way
for a macOS-hosted Linux container to use the corresponding sandbox VM
namespace. These are standard OCI namespace choices and are useful to generic
orchestrators that need host-versus-private IPC or hostname-domain selection.

Containerization commit `f842dcf` adds the optional
`LinuxContainer.Configuration.hostIPCNamespace` and
`LinuxContainer.Configuration.hostUTSNamespace` flags. Both default to private.
When requested, runtime-spec construction omits only the matching OCI namespace
entry; the container therefore retains the sandbox VM's IPC or UTS namespace.
Container commit `b63e2af` exposes the same generic settings as
`--ipc host|private` and `--uts host|private`, and Compose commit `3de532af`
maps the standard Compose fields with Docker Compose V2 parity coverage.

This is deliberately limited to generic OCI namespace configuration in the
macOS-hosted Linux guest. It adds no Docker or Compose model, Windows behavior,
host-Linux path, inter-container IPC sharing, or macOS host namespace access.

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
