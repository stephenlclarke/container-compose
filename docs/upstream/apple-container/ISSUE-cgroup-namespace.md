# Feature request: expose generic cgroup namespace selection

## Feature or enhancement request details

`container` had no generic CLI or persisted configuration surface for choosing
the cgroup namespace. As a result, a macOS user could not request the sandbox
VM cgroup namespace even after the lower runtime could omit the OCI cgroup
namespace entry.

Container commit `9dd6cd9` adds `container run|create --cgroupns host|private`,
persists the choice as `ContainerConfiguration.hostCgroupNamespace`, and
forwards it to the generic Containerization configuration. The lower-runtime
implementation is Containerization commit `f72625f`; Compose commit `1f182f02`
uses the same generic consumer surface for the standard Compose `cgroup` field.

This is a macOS Linux-guest namespace selection only. It does not introduce
Docker or Compose types in Container source, Windows behavior, host-Linux
behavior, cgroup parent support, or macOS host cgroup control.

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
