# Support Docker Compose local Deploy update and scheduler metadata

## Summary

- Preserves compose-go normalized `deploy.update_config`, `deploy.rollback_config`, and `deploy.placement` metadata in `container compose config --format json`.
- Accepts both documented `deploy.update_config.order` values in local mode and includes Deploy metadata in the recreate fingerprint.
- Keeps Swarm placement, rollback, timing, and parallelism orchestration out of the Apple runtime bridge; pids reservations plus device/generic resource reservations or limits remain rejected.
- Adds Go and Swift normalizer coverage plus a local-only Docker Compose parity target for config and dry-run `up --no-start`.
- Updates the current parity ledger so `STATUS.md` no longer lists accepted scheduler metadata as missing functionality.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose V2 accepts `deploy.update_config`, `deploy.rollback_config`, and `deploy.placement` in local mode, preserves those blocks in config output, and still plans ordinary local service creation. It accepts `start-first` as metadata while the local `up` path uses ordinary container replacement rather than Swarm rolling-update scheduling.

The upstream review did not find a Docker Compose, Compose Spec, compose-go, Apple container, or Apple containerization PR that changes this behavior. The implementation follows the Docker Deploy Specification and compose-go's normalized `types.DeployConfig` JSON tags instead of reimplementing the Deploy schema in Swift.

## Implementation Details

- Uses the raw compose-go `DeployConfig` value in the normalizer's service JSON model.
- Uses the Swift `ComposeService.deploy` `ComposeValue` field for both config output and recreate fingerprints.
- Treats `update_config.delay`, `parallelism`, monitoring, and failure controls as local metadata because Docker Compose does not apply Swarm rolling-update orchestration in local mode.
- Added `Tools/parity/check-compose-deploy-scheduler-metadata.sh` plus `make docker-compose-deploy-scheduler-metadata-parity`.

## Validation

```sh
gh search issues "deploy placement rollback_config compose local" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo apple/container --repo apple/containerization --limit 30
gh search prs "deploy placement rollback_config compose local" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo apple/container --repo apple/containerization --limit 30
docker-compose --project-directory "$tmpdir" -f "$tmpdir/compose.yml" config --format json
docker-compose --dry-run --project-directory "$tmpdir" -f "$tmpdir/compose.yml" up --no-start
go test ./...
swift test --disable-automatic-resolution --filter 'normalizesStartFirstDeployUpdateThroughComposeGo|upAcceptsStartFirstDeployUpdatesAndRecreatesWhenOrderChanges|runAcceptsStartFirstDeployUpdateMetadata|upRecreatesExistingContainersWhenDeployMetadataChanges|upIgnoresDeployUpdateDelayInLocalMode'
bash -n Tools/parity/check-compose-deploy-scheduler-metadata.sh
make docker-compose-deploy-scheduler-metadata-parity
make test
make coverage-check
make check
npx --yes markdownlint-cli2 STATUS.md docs/upstream/container-compose/ISSUE-deploy-scheduler-metadata.md docs/upstream/container-compose/PR-deploy-scheduler-metadata.md
git diff --check
```

## Compatibility

This change makes `container-compose` config output and recreate decisions more faithful for Compose files that Docker Compose already accepts in local mode. It does not implement Swarm placement, multi-node scheduling, rollback orchestration, or rolling-update timing/parallelism.

## Remaining Risks

- If Apple exposes placement or rollback orchestration primitives, `container-compose` should map the preserved metadata into those APIs instead of treating it as local scheduler metadata.
- Docker Compose may add new Deploy fields through compose-go; unsupported runtime-bearing fields should continue to be validated before side effects.
