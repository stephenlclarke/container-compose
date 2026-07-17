# Compose compatibility gap: OOM score adjustment

## Compose surface

`services.<name>.oom_score_adj` sets the Linux OOM-killer score adjustment for
the service process.

## Docker Compose V2 behavior

Docker Compose accepts `oom_score_adj` as a service attribute and passes the
value to the container runtime.

Reference: <https://docs.docker.com/reference/compose-file/services/#oom_score_adj>

## Implemented behavior

`container-compose` accepts scores from `-1000` through `1000`, validates the
range before side effects, and projects the value to the typed service process,
its healthcheck process, and one-off `compose run` containers. The latter emits
the generic `container run --oom-score-adj SCORE` argument.

The matched Containerization and Container forks preserve the optional value in
their generic process models and pass it to the OCI runtime. An omitted value
leaves the runtime default unchanged.

## Boundaries

- `oom_kill_disable` remains unsupported because it requires separate cgroup
  memory policy rather than a per-process OCI score adjustment.
- This does not create memory limits, reservations, or swap policy.
- Compose owns the Docker-compatible range validation; the forks remain generic
  OCI process adapters.

## Ownership

The fork changes are recorded under `docs/upstream/apple-containerization/` and
`docs/upstream/apple-container/`. No Apple remote was modified.
