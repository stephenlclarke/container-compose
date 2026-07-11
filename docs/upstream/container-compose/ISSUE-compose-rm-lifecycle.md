# Align `compose rm` lifecycle parity

## Summary

`container compose rm [OPTIONS] [SERVICE...]` should remove only stopped service containers unless `--stop` is requested, and it should treat service containers that disappear during cleanup as already absent.

Docker Compose documents `rm` as removing stopped service containers. The `--stop` option stops containers first when required, while `--force` only suppresses the confirmation prompt.

## Current Gap

Before this slice, the runtime path resolved deterministic service container names when no matching runtime container was present. That could make `rm -f SERVICE` try to delete an already missing container or a still-running service container.

Network deletion had a related cleanup race: a network removed between existence preflight and deletion could still surface a not-found error even though volume deletion already treated that race as idempotent.

## Docker Compose Reference

- Docker Compose `rm` reference: <https://docs.docker.com/reference/cli/docker/compose/rm/>
- Docker Compose issue [#6968](https://github.com/docker/compose/issues/6968) documents `No stopped containers` behavior around stopped-container discovery.

Local parity on this MacBook Pro:

```sh
docker-compose -p ccparityrm -f compose.yml rm -f app
docker-compose -p ccparityrm -f compose.yml rm --stop --force app
make docker-compose-rm-parity
```

## Expected Behavior

- `container compose rm -f SERVICE` reports `No stopped containers` when the service container is missing or only running containers match.
- `container compose rm --stop --force SERVICE` stops running service containers before removal.
- `container compose rm --stop --force SERVICE` removes already stopped service containers without issuing an unnecessary stop call.
- Missing containers, missing networks, and missing volumes encountered during cleanup are treated as already absent.

## Remaining Gap

No upstream Apple runtime primitive is needed for this slice. It is local Compose orchestration behavior over the existing container lifecycle, discovery, network, and volume APIs.
