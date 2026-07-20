# Compose compatibility gap: local network attachable metadata

## Compose surface

`networks.<name>.attachable`

## Docker Compose V2 behavior

Docker Compose preserves `attachable: true` in normalized configuration. Docker documents its behavioral purpose as permitting manually started containers to join an overlay network in addition to service containers. Local bridge networks already permit standalone attachment; the restriction is meaningful for Swarm overlay networks.

References:

- <https://docs.docker.com/reference/compose-file/networks/#attachable>
- <https://docs.docker.com/reference/cli/docker/network/create/#options>

## Current container-compose behavior

The compose-go normalizer preserves `attachable: true` in the typed project model. The Compose runtime accepts it for an Apple vmnet local network and preserves it in `config`/`convert` output. The runtime already lets a standalone `container run --network <network>` join the local network, so no Docker-specific or Apple-fork primitive is necessary.

`attachable: false` has no extra macOS behavior to emulate. Docker's documented standalone-attachment restriction applies to Swarm/overlay networks, which are intentionally outside this macOS local-runtime scope.

## Ownership

`container-compose`

This is Compose-model compatibility work. It deliberately does not alter `apple/container` or `containerization`, add a Docker-shaped flag to either fork, or claim Swarm/overlay support.

## Acceptance evidence

1. Docker Compose V2 config output retains `networks.backend.attachable: true`.
2. `container compose config --format json` exposes the same field without an unsupported marker.
3. `container compose --dry-run up` accepts the Compose file before side effects.
4. An isolated macOS runtime starts the project and a standalone `container run --network` joins its vmnet network.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `Status.md`.
- [x] This issue contains no Apple-fork change because the required macOS primitive already exists.
