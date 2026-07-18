# Feature request: expose generic IPC and UTS namespace selection

## Feature or enhancement request details

`container` had no generic CLI or persisted configuration surface for choosing
the IPC or UTS namespace. As a result, a macOS user could not request the
sandbox VM IPC or hostname-domain namespace even after the lower runtime could
omit the matching OCI namespace entry.

Container commit `b63e2af` adds `container run|create --ipc host|private` and
`--uts host|private`, persists the choices as
`ContainerConfiguration.hostIPCNamespace` and `hostUTSNamespace`, and forwards
them to generic Containerization configuration. The lower-runtime implementation
is Containerization commit `f842dcf`; Compose commit `3de532af` uses the same
generic consumer surface for the standard Compose `ipc` and `uts` fields.

This is a macOS Linux-guest namespace selection only. It does not introduce
Docker or Compose types in Container source, Windows behavior, host-Linux
behavior, IPC sharing between containers, or macOS host namespace access.

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
