# Compose compatibility gap: memory reservation

## Compose surface

`services.<name>.mem_reservation` defines a service container's soft memory
reservation.

## Docker Compose V2 behavior

Docker documents `--memory-reservation` as a soft limit and requires it to be
lower than an explicit `--memory` hard limit for the reservation to take
precedence.

Reference:

- <https://docs.docker.com/engine/containers/resource_constraints/>

## Implemented behavior

`container-compose` accepts `mem_reservation`, validates the normalized byte
count before any runtime side effects, and carries it in the typed
service-create plan. Zero leaves the runtime default unchanged. When a service
also supplies `mem_limit`, the reservation must be strictly lower. `up`,
`create`, and one-off `run` containers render the generic
`container run --memory-reservation VALUE` bridge until direct typed creation
replaces the command vector.

## Boundaries

- The reservation is a soft memory threshold, not a hard cap.
- `memswap_limit`, `mem_swappiness`, and `oom_kill_disable` remain separate
  runtime gaps.
- Compose owns Docker-compatible relationship validation; the forks retain
  generic Linux resource transport and OCI projection.

## Ownership

The supporting fork work is recorded under `docs/upstream/apple-containerization/`
and `docs/upstream/apple-container/`. No Apple remote was modified.
