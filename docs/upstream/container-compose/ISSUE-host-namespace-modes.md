# Support Host Namespace Modes

## Summary

`container-compose` should accept the host namespace subset of Docker Compose service namespace fields:

- `network_mode: host`
- `pid: host`

Before this slice, `network_mode` accepted only `none`, and any non-empty `pid` value was rejected as a generic runtime gap. The stephenlclarke fork-backed runtime stack now exposes the missing PID primitive through `container run/create --pid host` and the host-network path through `container run/create --network host`.

## Acceptance Criteria

- `compose up` and `compose run` accept `network_mode: host`.
- `network_mode: host` service containers emit `container run/create --network host` and do not receive a Compose project network attachment.
- `compose up` and `compose run` accept `pid: host`.
- `pid: host` service containers emit `container run/create --pid host` while retaining ordinary service networking.
- `network_mode: service:NAME`, `network_mode: container:NAME`, `pid: service:NAME`, and `pid: container:NAME` remain explicit unsupported modes until runtime namespace-join primitives exist.
- Focused unit tests cover steady-state services and one-off `run`.
- A local-only Docker Compose parity target covers Docker config/inspect behavior and container-compose dry-run behavior.

## Parity Notes

Docker Compose references:

- Compose service `network_mode`: <https://docs.docker.com/reference/compose-file/services/#network_mode>
- Compose service `pid`: <https://docs.docker.com/reference/compose-file/services/#pid>

Upstream checks before implementation:

- `apple/container` issue [#55](https://github.com/apple/container/issues/55) records upstream host-network demand and the current stock-runtime limitation. No open implementation PR was found for Docker-compatible `--network host` or `--pid host`.
- `apple/containerization` issues, PRs, and discussions for PID host namespace terms: no overlapping implementation found.
- Relevant Docker Compose host-network reports include `docker/compose#4548`, `docker/compose#6507`, and `docker/compose#10464`.
- Compose Spec issue `compose-spec/compose-spec#65` explicitly discusses service-mode namespace sharing through `network_mode`, `pid`, and `ipc`.
- The cached Docker Compose e2e fixture checkout contains `pkg/e2e/fixtures/network-test/compose.yaml` and `pkg/e2e/fixtures/no-deps/network-mode.yaml` for `network_mode: service:db`, plus `pkg/e2e/fixtures/network-links/compose.yaml` for `network_mode: bridge`; no reusable `network_mode: host` / `pid: host` fixture was present, so this slice uses a minimal local parity fixture.

## Notes

The Apple runtime mapping is host-scoped to the Linux sandbox VM boundary. Service/container namespace sharing is tracked separately because it requires joining another container's namespace rather than selecting the runtime host namespace.
