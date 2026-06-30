# Feature or Enhancement Request Details

`container run` and `container create` should expose a small PID namespace option for the host-PID mode supported by the runtime package.

Docker and Docker Compose both expose `--pid host` / `pid: host` for workloads that need to see or interact with the host PID namespace. For Apple container workloads, the comparable host is the sandbox VM namespace used by the Linux runtime. The local `containerization` fork now exposes `LinuxContainer.Configuration.hostPIDNamespace`; `apple/container` needs to pass that primitive through the container configuration and CLI/API client layers.

Requested shape:

- Add a `ContainerConfiguration.hostPIDNamespace` field that defaults to `false` when decoding older saved configurations.
- Add `--pid <mode>` to the shared run/create management options.
- Accept only `host` for now; reject service/container namespace joining until there is a Docker-compatible namespace-join primitive.
- Pass the boolean to `LinuxContainer.Configuration.hostPIDNamespace` in the Linux runtime service.

## Upstream Search

Checked before implementation:

- `apple/container` issues and PRs for `pid namespace` and `pid host` terms: no matching open implementation found.
- `apple/container` discussions search for PID host namespace terms: no matching discussion found.
- Host-network mode is tracked separately in [ISSUE-host-network-mode.md](ISSUE-host-network-mode.md).
- Docker Compose / Compose Spec references show `pid: host` and `pid: service:NAME` are valid Compose concepts, but service/container namespace sharing is a separate runtime join primitive.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
