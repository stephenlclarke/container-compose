# Preserve Deploy scheduler metadata in config output

## Summary

- Preserves compose-go normalized `deploy.rollback_config` and `deploy.placement` metadata in `container compose config --format json`.
- Keeps local orchestration behavior unchanged: scheduler metadata is accepted, not mapped to Apple runtime placement or rollback primitives.
- Keeps unsupported deploy validation for start-first updates and pids/device/generic resource reservations or limits.
- Adds Go and Swift normalizer coverage plus a local-only Docker Compose parity target for config and dry-run `up --no-start`.
- Updates the current parity ledger so `STATUS.md` no longer lists accepted scheduler metadata as missing functionality.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose V2 accepts `deploy.rollback_config` and `deploy.placement` in local mode, preserves those blocks in config output, and still plans ordinary local service creation. `container-compose` already accepted the fields but dropped them from normalized config output, which made the visible parity ledger and the command output under-report the supported local-mode subset.

The upstream review did not find a Docker Compose, Compose Spec, compose-go, Apple container, or Apple containerization PR that changes this behavior. The implementation follows the Docker Deploy Specification and compose-go's normalized `types.DeployConfig` JSON tags instead of reimplementing the Deploy schema in Swift.

## Implementation Details

- Added the raw compose-go `DeployConfig` pointer to the normalizer's service JSON model.
- Added a Swift `ComposeService.deploy` `ComposeValue` field so config output can preserve deploy metadata without adding runtime behavior.
- Excluded the raw deploy metadata from Compose recreate hashes; the typed fields that already drive runtime behavior remain part of the existing hash path.
- Added `Tools/parity/check-compose-deploy-scheduler-metadata.sh` plus `make docker-compose-deploy-scheduler-metadata-parity`.

## Validation

```sh
gh search issues "deploy placement rollback_config compose local" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo apple/container --repo apple/containerization --limit 30
gh search prs "deploy placement rollback_config compose local" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo apple/container --repo apple/containerization --limit 30
docker-compose --project-directory "$tmpdir" -f "$tmpdir/compose.yml" config --format json
docker-compose --dry-run --project-directory "$tmpdir" -f "$tmpdir/compose.yml" up --no-start
go test ./...
swift test --disable-automatic-resolution --filter 'normalizesSupportedDeployLocalFieldsThroughComposeGo|normalizesUnsupportedDeployFields'
bash -n Tools/parity/check-compose-deploy-scheduler-metadata.sh
make docker-compose-deploy-scheduler-metadata-parity
npx --yes markdownlint-cli2 README.md BUILD.md STATUS.md docs/bug-report-how-to.md docs/parity/compose-cli-surface.md docs/upstream/container-compose/ISSUE-deploy-scheduler-metadata.md docs/upstream/container-compose/PR-deploy-scheduler-metadata.md
git diff --check
```

## Compatibility

This change makes `container-compose` config output more faithful for Compose files that Docker Compose already accepts in local mode. It does not implement Swarm placement, multi-node scheduling, rollback orchestration, or start-first update replacement.

## Remaining Risks

- If Apple exposes placement or rollback orchestration primitives, `container-compose` should map the preserved metadata into those APIs instead of treating it as local scheduler metadata.
- Docker Compose may add new Deploy fields through compose-go; unsupported runtime-bearing fields should continue to be validated before side effects.
