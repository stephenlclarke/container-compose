# Compose compatibility: local Deploy update and scheduler metadata

## Surface

`services.<name>.deploy.update_config`, `services.<name>.deploy.rollback_config`, and `services.<name>.deploy.placement`

## Current Docker Compose behavior

Docker Compose V2 accepts `deploy.update_config`, `deploy.rollback_config`, and `deploy.placement` in local mode. `docker-compose config --format json` preserves those metadata blocks, and dry-run local `up --no-start SERVICE` proceeds through the ordinary service creation plan.

Docker Compose V2 accepts both documented `deploy.update_config.order` values. Its local `up` path uses ordinary container replacement when Deploy metadata changes; Swarm update timing and scheduler controls are not applied locally.

## Current container-compose behavior

`container-compose` accepts these fields as local-mode metadata and preserves the compose-go normalized `deploy` block in `config --format json`. The full Deploy block participates in the recreate fingerprint, so a metadata change triggers local container replacement. The fields are not projected to Apple runtime flags, and local orchestration does not claim Swarm placement, rollback, timing, or parallelism behavior.

## Supported subset

- `deploy.rollback_config.parallelism`
- `deploy.rollback_config.delay`
- `deploy.rollback_config.failure_action`
- `deploy.rollback_config.monitor`
- `deploy.rollback_config.max_failure_ratio`
- `deploy.rollback_config.order`
- `deploy.update_config.parallelism`
- `deploy.update_config.delay`
- `deploy.update_config.failure_action`
- `deploy.update_config.monitor`
- `deploy.update_config.max_failure_ratio`
- `deploy.update_config.order: stop-first`
- `deploy.update_config.order: start-first`
- `deploy.placement.constraints`
- `deploy.placement.preferences`
- `deploy.placement.max_replicas_per_node`

## Remaining gaps

- Swarm scheduler placement decisions
- Rollback orchestration after failed rolling updates
- Swarm update timing, failure handling, and parallelism orchestration
- pids reservations, plus device and generic resource reservations or limits

## Upstream references

- Docker Deploy Specification: <https://docs.docker.com/reference/compose-file/deploy/>
- Docker Compose `up` reference: <https://docs.docker.com/reference/cli/docker/compose/up/>
- Upstream scan found no approved Docker Compose, Compose Spec, compose-go, Apple container, or Apple containerization PR that changes local-mode handling for these Deploy metadata fields.
