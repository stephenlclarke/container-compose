# Feature or Enhancement Request Details

`container run` and `container create` should expose a narrow `--network host` mode so higher-level Compose clients can map `network_mode: host` without creating a user network named `host` or attaching the service to the Compose project network.

Docker and Docker Compose both treat `host` as a reserved network mode rather than a normal network resource. In the Apple container architecture, the runtime host is the Linux sandbox VM boundary rather than the macOS host namespace. The Stephen fork-backed implementation keeps that distinction explicit while giving downstream clients a Docker-compatible CLI/API surface:

- Reserve `host` beside the existing `none` network mode name.
- Reject user-created networks named `host`.
- Reject `--network host` when it is combined with other networks or attachment properties.
- Persist the request as `ContainerConfiguration.hostNetwork`, defaulting to `false` when decoding older saved configurations.
- Use the built-in host-facing network attachment for runtime startup.
- Skip socket forwarder setup for host-network containers so published ports are not treated as Docker bridge-style forwards.

## Upstream Search

Checked before implementation:

- `apple/container` issue [#55](https://github.com/apple/container/issues/55) records demand for host network access and current stock-runtime limitations.
- `apple/container` PR and discussion searches for `network host`, `--network host`, and `host network` found no active implementation PR.
- `apple/containerization` did not need a network namespace change for this container-level mapping.
- Docker Compose / Compose Spec references show `network_mode: host`, `network_mode: service:NAME`, and `network_mode: container:NAME` are separate Compose concepts; service/container namespace sharing remains a separate runtime join primitive.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
