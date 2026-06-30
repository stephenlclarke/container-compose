# Accept `up --menu` with exit-control options

## Compose surface

`docker compose up --menu --abort-on-container-exit`

`docker compose up --menu --abort-on-container-failure`

`docker compose up --menu --exit-code-from SERVICE`

## Docker Compose v2 behavior

Docker Compose V2 accepts `up --menu` with exit-control options in local dry-run mode. It proceeds through the ordinary service create plan instead of rejecting the option combination.

Upstream context checked before this slice:

- No Docker Compose, Compose Spec, compose-go, or Moby issue/PR/discussion directly argued for rejecting `up --menu` with exit-control options.
- Local Docker Compose 5.2.0 accepted `up --menu --abort-on-container-exit SERVICE` in dry-run mode.

## Current container-compose behavior

Before this slice, `container-compose` rejected `up --menu` when any exit-control option was present, even though the normal exit-control waiter and the menu log follower were both implemented in this repository.

## Likely owner

container-compose design gap.

The Apple runtime does not need a new primitive for this combination. `container-compose` can start the graph detached, follow logs through the Compose-owned menu session, and run the existing exit-control waiter beside the log follower. The first exit-control result tears the project down and becomes the plugin exit status.

## Expected behavior

- `container compose up --menu --abort-on-container-exit SERVICE` is accepted.
- `container compose up --menu --abort-on-container-failure SERVICE` is accepted.
- `container compose up --menu --exit-code-from SERVICE` is accepted and returns the selected service status.
- `up --menu --watch` remains a separate documented gap until the watch and menu lifecycle loops are reconciled.
