# Implement attached `compose up --menu`

## Summary

`container compose up --menu SERVICE` should provide Docker Compose-style attached shortcut handling instead of rejecting the option or leaving foreground runtime ownership to a single service container.

Docker Compose treats `--menu` as an optional boolean flag and enables an attached helper menu only when terminal conditions allow it. `container-compose` already supports the underlying detached start and log-follow primitives, so the menu can live in this repository as a Compose-owned controller without requiring an Apple interactive attach primitive.

## Acceptance Criteria

- `container compose up --menu SERVICE` starts the selected service graph detached and follows attachable service logs through a Compose-owned menu session.
- `container compose up --menu=false`, `--menu=0`, and `--menu=no` explicitly disable menu activation, including when `COMPOSE_MENU` is set.
- `container compose up --menu=true --no-start SERVICE` remains a no-op for the menu and renders the normal create plan in dry-run mode.
- The menu supports `d` detach, `w` watch toggle for services with `develop.watch`, first `Ctrl+C` graceful stop, second `Ctrl+C` force stop, and Enter redraw.
- `up --menu` with `up --watch` remains rejected until Docker-compatible combined menu/watch semantics are implemented.
- Focused tests cover argument rewriting, parser integration, help status, dry-run behavior, menu key handling, menu action handling, menu log-follow orchestration, exit-control combination behavior, and the documented watch incompatibility guard.

## Notes

This is a Compose-side compatibility improvement. Docker Desktop-only shortcuts are intentionally absent because they target Docker Desktop UI surfaces rather than Apple container runtime APIs.
