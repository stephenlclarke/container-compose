# Accept Deploy CPU and memory reservations in local mode

## Summary

- Stops reporting `deploy.resources.reservations.cpus` and `deploy.resources.reservations.memory` as unsupported deploy fields.
- Keeps local orchestration behavior unchanged: the fields are accepted as scheduler metadata, not projected to Apple runtime hard-limit flags.
- Keeps pids, device, and generic-resource reservations rejected as separate scheduler/runtime gaps.
- Adds focused Go and Swift normalizer/orchestration coverage.
- Adds a local-only Docker Compose parity target for config and dry-run `up --no-start`.
- Bumps the plugin patch version to `0.1.5`.
- Updates README, status, parity docs, and contributor build docs.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose V2 accepts CPU and memory Deploy reservations in local mode, preserves them in config output, and still proceeds with ordinary local service creation. `container-compose` previously treated those scheduler hints as Apple runtime gaps and rejected otherwise Docker-compatible Compose files before any local orchestration could run.

The upstream review did not find Compose-side guidance to reject these fields in local mode. This slice treats CPU and memory reservations like local-mode Deploy metadata: accepted to avoid false unsupported-feature failures, without claiming hard reservation or scheduler semantics.

## Implementation Details

- Removed CPU and memory reservations from the normalizer's unsupported deploy field list.
- Kept pids, device, and generic-resource reservations in the unsupported list.
- Updated Go unsupported-deploy tests and Swift compose-go normalization coverage.
- Added Swift orchestration acceptance coverage for normalized CPU/memory reservations.
- Added `Tools/parity/check-compose-deploy-resource-reservations.sh` plus `make docker-compose-deploy-resource-reservations-parity`.

## Validation

```sh
gh search issues "deploy resources reservations memory cpus compose local" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo moby/moby --repo moby/buildkit --limit 30
gh search prs "deploy resources reservations memory cpus compose local" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo moby/moby --repo moby/buildkit --limit 30
gh api graphql -f query='query($q:String!){ search(query:$q, type:DISCUSSION, first:10){ nodes { ... on Discussion { title url createdAt updatedAt repository { nameWithOwner } } } } }' -f q='deploy resources reservations memory cpus compose local repo:docker/compose repo:compose-spec/compose-spec repo:compose-spec/compose-go repo:moby/moby repo:moby/buildkit'
docker-compose --project-directory "$tmpdir" -f "$tmpdir/compose.yml" config --format json
docker-compose --dry-run --project-directory "$tmpdir" -f "$tmpdir/compose.yml" up --no-start
go test ./...
swift test --disable-automatic-resolution --filter 'normalizesUnsupportedDeployResourceFieldsThroughComposeGo|upAcceptsDeployCPUAndMemoryReservationsAsLocalMetadata|upRejectsUnsupportedDeployResourceReservationsAsAppleContainerRuntimeGaps'
python3 -m unittest Tools/release/test_update_homebrew_formula.py
bash -n Tools/parity/check-compose-deploy-resource-reservations.sh
make docker-compose-deploy-resource-reservations-parity
make docker-compose-cli-surface-parity
make check
make cli-smoke-built
make coverage-check
npx --yes markdownlint-cli2 README.md BUILD.md STATUS.md docs/bug-report-how-to.md docs/parity/compose-cli-surface.md docs/upstream/container-compose/ISSUE-deploy-resource-reservations.md docs/upstream/container-compose/PR-deploy-resource-reservations.md
git diff --check
```

## Compatibility

This change makes `container-compose` more permissive for Compose files that Docker Compose already accepts in local mode. It does not implement hard reservation guarantees, scheduler placement, device reservation, or generic resource behavior for the Apple runtime.

## Remaining Risks

- If a future Apple runtime exposes explicit reservation or scheduler primitives, `container-compose` may need to preserve and project this metadata instead of accepting it as local no-op metadata.
- pids, device, and generic-resource reservations remain unsupported pending separate runtime or scheduler analysis.
