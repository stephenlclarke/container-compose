# Compose compatibility gap: network driver options

## Compose surface

- `networks.<name>.driver_opts`
- `services.<name>.networks.<network>.driver_opts`

## Docker Compose v2 behavior

Docker Compose accepts top-level network driver options and passes them to the selected Docker network driver when the project network is created. Docker Compose also preserves per-service network attachment driver options in normalized config; endpoint option behavior is driver-dependent.

```yaml
services:
  api:
    image: alpine:3.20
    networks:
      backend:
        driver_opts:
          com.docker.network.driver.mtu: "1450"
networks:
  backend:
    driver_opts:
      com.docker.network.bridge.host_binding_ipv4: 127.0.0.1
      com.docker.network.driver.mtu: "1450"
```

References:

- Compose networks `driver_opts`: <https://docs.docker.com/reference/compose-file/networks/#driver_opts>
- Compose services network attachment `driver_opts`: <https://docs.docker.com/reference/compose-file/services/#driver_opts>
- Docker bridge driver options: <https://docs.docker.com/engine/network/drivers/bridge/#options>
- Apple network API currently exposes plugin options for network creation and hostname, aliases, MAC, and MTU for attachments. No arbitrary endpoint-driver option surface was found in the current reviewed forks.

## Current container-compose behavior

Before this change, compose-go normalized top-level network `driver_opts`, but the Swift normalized model dropped them before orchestration. Service-level network attachment `driver_opts` had a narrower partial implementation: Docker-compatible MTU values were accepted and mapped to `container --network name,mtu=...`; other endpoint options were rejected before side effects.

With this change:

- Top-level `networks.<name>.driver_opts` are preserved in the Swift normalized project model.
- `compose config --format json` reports top-level network driver options using the internal `driverOpts` key.
- `up` dry-run renders repeatable `container network create --option key=value` arguments before service containers are created.
- The direct API path sends the same options through `NetworkConfiguration.options`.
- Arbitrary service attachment driver options remain blocked because Apple attachment options do not expose a generic endpoint option map.

## Likely owner

`container-compose` owns the Compose model normalization, Apple network-create option mapping, dry-run rendering, and Docker Compose parity tests.

`apple/container` already exposes network-create plugin options. A future Apple change would be needed only for generic service endpoint driver options, where `AttachmentOptions` would need a Docker-compatible option surface beyond the currently exposed MTU field.

## Minimal example

```yaml
services:
  api:
    image: alpine:3.20
    command: ["true"]
    networks:
      - backend
networks:
  backend:
    driver_opts:
      com.docker.network.bridge.host_binding_ipv4: 127.0.0.1
      com.docker.network.driver.mtu: "1450"
```

Expected fork-backed behavior:

- `container compose config --format json` preserves the network driver option values in the normalized network model.
- `container compose --dry-run up api` emits `container network create --option com.docker.network.bridge.host_binding_ipv4=127.0.0.1 --option com.docker.network.driver.mtu=1450`.
- The direct API resource path sends the same options to Apple network creation.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `PLAN.md`.
