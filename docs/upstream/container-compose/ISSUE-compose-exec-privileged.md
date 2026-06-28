# Support Privileged Compose Exec

## Summary

`container compose exec --privileged` should run through the direct exec path instead of failing before runtime execution.

The local `stephenlclarke/container` fork now exposes a process-level privileged exec primitive through `ProcessConfiguration.privileged` and `container exec --privileged`. With that runtime surface available, `container-compose` can mark the exposed `exec` command surface supported and pass the flag through attached exec, detached exec, lifecycle hooks, and `develop.watch sync+exec` hooks.

## Acceptance Criteria

- `container compose help exec` reports `Support: supported`.
- `container compose help exec` shows `--privileged` as supported.
- `compose exec --privileged` passes `privileged: true` to attached runtime exec requests.
- Detached `compose exec --privileged --detach` passes `privileged: true` to detached runtime exec requests.
- Dry-run output renders `container exec --privileged ...`.
- Lifecycle hooks with `privileged: true` pass the flag to direct exec and render it in dry-run output.
- `develop.watch sync+exec` hooks with `privileged: true` pass the flag to direct exec.
- Runtime smoke includes a Dockerfile and compose.yml-backed dry-run check.

## Notes

This is a Compose-side integration slice over the generic process exec primitive in `stephenlclarke/container`. Service-level `privileged: true` is tracked separately in [ISSUE-service-privileged.md](ISSUE-service-privileged.md) because it is a service container create/run concern rather than an exec concern.
