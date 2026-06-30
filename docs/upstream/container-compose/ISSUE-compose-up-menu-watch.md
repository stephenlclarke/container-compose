# Accept `up --menu --watch`

## Compose surface

`docker compose up --menu --watch SERVICE`

## Docker Compose v2 behavior

Docker Compose V2 accepts `up --menu --watch` in local dry-run mode. It renders the ordinary `up` create/start preview and ends with the dry-run interactive-run note instead of rejecting the option combination or printing a standalone watch plan.

Upstream context checked before this slice:

- No Docker Compose, Compose Spec, compose-go, or Moby issue/PR/discussion directly argued for rejecting `up --menu --watch`.
- Local Docker Compose 5.2.0 accepted `up --menu --watch SERVICE`, `up --menu=true --watch SERVICE`, and `up --menu=false --watch SERVICE` in dry-run mode.

## Current container-compose behavior

Before this slice, `container-compose` rejected `up --menu --watch` before loading the Compose project, even though the attached menu could already toggle watch with `w` and the standalone `up --watch` path was implemented.

## Likely owner

container-compose design gap.

The Apple runtime does not need a new primitive for this combination. `container-compose` can start the selected service graph through the existing menu-enabled `up` path, then start the existing watch engine in no-up mode before the menu renders so the first menu line accurately reports watch as enabled.

## Minimal example

```yaml
services:
  api:
    image: alpine:3.20
    develop:
      watch:
        - action: sync
          path: ./src
          target: /app/src
```

```sh
container compose --dry-run up --menu --watch api
container compose up --menu --watch api
```

## Acceptance Criteria

- `container compose up --menu --watch SERVICE` is accepted.
- Dry-run mode follows Docker Compose by rendering the ordinary detached create/start preview rather than a standalone watch plan.
- Attached terminal mode starts the menu with watch already enabled.
- Missing or malformed `develop.watch` metadata fails before runtime side effects in live menu-watch mode.
- Non-interactive environments that cannot host the menu continue to use the normal `up --watch` path when `--watch` is requested.
- `make docker-compose-up-menu-parity` requires Docker Compose and `container-compose` to accept `up --menu --watch`.
- README, status, parity docs, and upstream handoff notes no longer list `up --menu --watch` as a compatibility boundary.
