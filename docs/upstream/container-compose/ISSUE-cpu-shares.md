# Compose compatibility gap: CPU shares

## Compose surface

`services.<name>.cpu_shares` defines a service container's relative CPU weight
versus other containers.

## Docker Compose V2 behavior

The Compose specification describes `cpu_shares` as an integer relative CPU
weight. Docker's resource documentation describes CPU shares as a soft relative
weight whose default is `1024`.

References:

- <https://github.com/compose-spec/compose-spec/blob/master/spec.md#cpu_shares>
- <https://docs.docker.com/engine/containers/resource_constraints/#configure-the-default-cfs-scheduler>

## Implemented behavior

`container-compose` accepts `cpu_shares`, validates it before any runtime side
effects, and carries it in the typed service-create plan. Zero preserves the
runtime default; explicit non-zero weights begin at `2`. `up`, `create`, and
one-off `run` containers render the generic `container run --cpu-shares VALUE`
bridge until direct typed creation replaces the command vector.

## Boundaries

- CPU shares are a scheduler weight, not a CPU reservation or quota.
- `cpu_count`, `cpu_percent`, `cpu_period`, `cpu_quota`, real-time CPU fields,
  and `cpuset` remain separate runtime gaps.
- Compose owns Docker-compatible value policy; the forks retain generic Linux
  resource transport and OCI projection.

## Ownership

The supporting fork work is recorded under `docs/upstream/apple-containerization/`
and `docs/upstream/apple-container/`. No Apple remote was modified.
