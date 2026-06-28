# Align `compose rm` lifecycle parity

## Summary

- Resolves `compose rm` targets from actual project container discovery instead of fabricated deterministic names.
- Leaves running service containers untouched unless `--stop` is requested.
- Emits Docker Compose-compatible `No stopped containers` when no removable targets exist.
- Ignores containers that disappear during `rm` cleanup.
- Ignores networks that disappear between existence preflight and deletion.
- Adds focused Swift coverage plus a local-only Docker Compose `rm` parity target.

## Rationale

Docker Compose defines `rm` as removal of stopped service containers. Treating deterministic service names as removable targets made missing and running-container cases behave like delete requests rather than Compose lifecycle cleanup.

The change keeps the behavior local to `container-compose`: discovery decides which service containers are removable, `--stop` opts into stopping running targets, and not-found races are handled idempotently during cleanup.

## Validation

```sh
swift test --disable-automatic-resolution --filter resourceManager
swift test --disable-automatic-resolution --filter rm
make docker-compose-rm-parity
```

## Compatibility Notes

- `rm -f SERVICE` now matches Docker Compose by leaving running containers alone.
- `rm --stop --force SERVICE` removes running service containers after a stop.
- Stopped, exited, created, and dead service containers are removable without an extra stop call.
- The Docker-backed parity target is local-only and remains outside `make ci`.
