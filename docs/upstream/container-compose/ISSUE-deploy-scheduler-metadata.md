# Compose compatibility gap: Deploy scheduler metadata

## Surface

`services.<name>.deploy.rollback_config` and `services.<name>.deploy.placement`

## Current Docker Compose behavior

Docker Compose V2 accepts `deploy.rollback_config` and `deploy.placement` in local mode. `docker-compose config --format json` preserves both metadata blocks, and dry-run local `up --no-start SERVICE` proceeds through the ordinary service creation plan.

The Docker Deploy Specification documents `rollback_config` as the rollback policy block and `placement` as scheduler placement metadata. Local Compose does not require Swarm scheduling to preserve those fields in config output.

## Current container-compose behavior

`container-compose` accepts these fields as local-mode scheduler metadata and preserves the compose-go normalized `deploy` block in `config --format json`. The fields are not projected to Apple runtime flags, and local orchestration does not claim Swarm placement or rollback behavior.

## Supported subset

- `deploy.rollback_config.parallelism`
- `deploy.rollback_config.delay`
- `deploy.rollback_config.failure_action`
- `deploy.rollback_config.monitor`
- `deploy.rollback_config.max_failure_ratio`
- `deploy.rollback_config.order`
- `deploy.placement.constraints`
- `deploy.placement.preferences`
- `deploy.placement.max_replicas_per_node`

## Remaining gaps

- Swarm scheduler placement decisions
- Rollback orchestration after failed rolling updates
- `deploy.update_config.order: start-first`
- pids, device, and generic resource reservations or limits

## Upstream references

- Docker Deploy Specification: <https://docs.docker.com/reference/compose-file/deploy/>
- Upstream scan found no approved Docker Compose, Compose Spec, compose-go, Apple container, or Apple containerization PR that changes local-mode handling for `deploy.rollback_config` or `deploy.placement`.
