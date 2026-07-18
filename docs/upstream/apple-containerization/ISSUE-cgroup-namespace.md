# Feature request: expose the sandbox VM cgroup namespace

## Feature or enhancement request details

`LinuxContainer` always added an OCI cgroup namespace, leaving no generic way for
a macOS-hosted Linux container to use its sandbox VM's cgroup namespace. The
underlying OCI namespace is not Docker-specific and is useful to generic
orchestrators that need host-versus-private cgroup namespace selection.

Containerization commit `f72625f` adds the optional
`LinuxContainer.Configuration.hostCgroupNamespace` flag. The default remains a
private cgroup namespace. When requested, runtime-spec construction omits only
the OCI cgroup namespace entry; the container therefore retains the sandbox VM
cgroup namespace. Container commit `9dd6cd9` exposes the same generic setting as
`--cgroupns host|private`, and Compose commit `1f182f02` maps the standard
Compose `cgroup` field with Docker Compose V2 parity coverage.

This is deliberately limited to the macOS-hosted Linux guest's generic OCI
namespace configuration. It adds no Docker or Compose model, Windows behavior,
host-Linux path, cgroup parent management, or host cgroup hierarchy control.

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
