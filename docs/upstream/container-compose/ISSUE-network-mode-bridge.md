# Map Docker Compose `network_mode: bridge` to the macOS runtime default network

## Problem

Docker Compose V2 accepts `network_mode: bridge` as the Docker built-in bridge
network. Container Compose parsed that portable service value but rejected it as
an unsupported network mode, even though the macOS Container runtime already
has an equivalent built-in generic network named `default`.

The missing behavior is a narrow Compose adapter mapping, not an Apple runtime
primitive. It must not be confused with custom named network modes or
`network_mode: service:NAME`/`container:NAME`, which require a different
network-namespace lifecycle.

## Acceptance criteria

- Accept `network_mode: bridge` for `up`, `create`, and one-off `run`.
- Emit exactly `container --network default` and create no project-scoped
  Compose network for that service.
- Retain Compose V2 `config` parity for the `bridge` value.
- Preserve the diagnostic boundary for `service:NAME`, `container:NAME`, and
  arbitrary custom network names.
- State that the default bridge has no Compose service-name DNS, matching
  Docker's default-bridge behavior and the existing macOS runtime boundary.
- Cover direct orchestrator commands and a Docker Compose V2 fixture for
  configuration plus container-compose dry-run parity.

## Scope and compatibility

This is Compose-layer-only and works on macOS with the existing Container
runtime. It changes no fork and introduces no Linux-only or Windows behavior.
It intentionally does not claim source-scoped discovery, aliases, attachable
networks, custom drivers, or shared network namespaces.
