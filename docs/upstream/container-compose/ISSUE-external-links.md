# Compose compatibility gap: legacy external links

## Compose surface

`services.<name>.external_links`

## Docker Compose v2 behavior

Docker Compose accepts legacy `external_links` entries in either `CONTAINER` or `CONTAINER:ALIAS` form. The referenced container or service is managed outside the current Compose application. Docker Compose passes these references to the engine link surface as `external:alias`, letting the platform resolve the external container and make the alias visible inside the source container.

```yaml
services:
  api:
    image: alpine
    external_links:
      - legacy-db:db
    networks:
      - backend

networks:
  backend: {}
```

References:

- Compose service `external_links`: <https://docs.docker.com/reference/compose-file/services/#external_links>
- Docker Compose v2 `getLinks` implementation: <https://github.com/docker/compose/blob/main/pkg/compose/convergence.go>
- compose-go `ExternalLinks` model: <https://github.com/compose-spec/compose-go/blob/main/types/types.go>
- compose-go external-links loader coverage: <https://github.com/compose-spec/compose-go/blob/main/loader/tests/external_links_test.go>
- Related apple/container DNS/interface issues: [apple/container#456](https://github.com/apple/container/issues/456), [apple/container#457](https://github.com/apple/container/issues/457), [apple/container#310](https://github.com/apple/container/issues/310)
- Related apple/container host-entry PR direction: [apple/container#1340](https://github.com/apple/container/pull/1340)

## Current container-compose behavior

Before this change, `container-compose` rejected all `external_links` entries as an `apple/container` runtime gap.

With this change, `container-compose` supports the safe local subset that can be represented by the fork-backed host-entry and direct inspection primitives:

- The source service must have exactly one Compose network.
- The referenced existing apple/container container must be discoverable through `ContainerClient.get`.
- The referenced container must have exactly one attachment on the source service's runtime network.
- `CONTAINER:ALIAS` maps `ALIAS` to the referenced container's IPv4 address by generating a transient host entry. The current live execution path still renders that host entry as `--add-host ALIAS:IP` through the command-vector bridge.
- `CONTAINER` maps the container name as the alias.
- The resolved host entry is added to the transient service model, so config-hash recreate behavior detects external address changes.

Missing external containers, services without exactly one Compose network, and external containers without one matching runtime network are rejected before resources are created.

## Likely owner

container-compose for the safe local subset.

Full Docker parity still needs apple/container support for source-scoped DNS/link lookup, shared aliases, and richer external-service discovery so the plugin does not need to render static generated host entries.

## Minimal example

First create an external container attached to the same runtime network that the Compose project will use:

```sh
container network create external-links-demo_backend
container run --name legacy-db --detach --network external-links-demo_backend postgres:18
```

Then run this Compose project:

```yaml
name: external-links-demo

services:
  api:
    image: alpine
    command: ["sleep", "infinity"]
    external_links:
      - legacy-db:db
    networks:
      - backend

networks:
  backend: {}
```

Expected runtime behavior on the fork-backed integration branch:

- `container-compose` inspects `legacy-db`.
- `container-compose` verifies that `legacy-db` is attached to `external-links-demo_backend`.
- The `api` service container currently receives `--add-host db:<legacy-db-ipv4>` through the command-vector bridge.
- Multi-network external links, missing external containers, and external containers on a different network fail before resource creation.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `STATUS.md` and relevant upstream docs.
