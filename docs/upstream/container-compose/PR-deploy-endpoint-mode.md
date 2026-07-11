# Accept Deploy endpoint-mode metadata in local mode

## Summary

- Stops reporting `deploy.endpoint_mode` as an unsupported deploy field.
- Keeps local orchestration behavior unchanged: the field is accepted as Swarm metadata, not projected to an Apple runtime endpoint-mode primitive.
- Removes the stale Swift runtime-gap special-case for `deploy.endpoint_mode`.
- Adds focused Go and Swift normalizer coverage.
- Adds a local-only Docker Compose parity target for config and dry-run `up --no-start`.
- Updates README, status, parity docs, and contributor build docs.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose V2 accepts `deploy.endpoint_mode` in local mode, preserves it in config output, and still proceeds with ordinary local service creation. `container-compose` previously treated the field as an Apple networking runtime gap and rejected otherwise Docker-compatible Compose files before any local orchestration could run.

The upstream review did not find Compose-side guidance to reject the field in local mode. The relevant upstream hits are Moby Swarm DNS/VIP discussions, so this slice treats `endpoint_mode` like local-mode Deploy metadata: accepted and preserved enough to avoid false unsupported-feature failures, without claiming Swarm VIP or DNSRR semantics.

## Implementation Details

- Removed `endpoint_mode` from the normalizer's unsupported deploy field list.
- Removed the Swift `deploy.endpoint_mode` special-case error.
- Updated Go unsupported-deploy tests and Swift compose-go normalization coverage.
- Added `Tools/parity/check-compose-deploy-endpoint-mode.sh` plus `make docker-compose-deploy-endpoint-mode-parity`.

## Validation

```sh
gh search issues "deploy endpoint_mode local compose" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo moby/moby --repo moby/buildkit --limit 30
gh search prs "deploy endpoint_mode" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo moby/moby --repo moby/buildkit --limit 30
gh api graphql -f query='query($q:String!){ search(query:$q, type:DISCUSSION, first:10){ nodes { ... on Discussion { title url createdAt updatedAt repository { nameWithOwner } } } } }' -f q='deploy endpoint_mode repo:docker/compose repo:compose-spec/compose-spec repo:compose-spec/compose-go repo:moby/moby repo:moby/buildkit'
docker-compose --project-directory "$tmpdir" -f "$tmpdir/compose.yml" config --format json
docker-compose --dry-run --project-directory "$tmpdir" -f "$tmpdir/compose.yml" up --no-start
go test ./...
swift test --disable-automatic-resolution --filter 'normalizesUnsupportedDeployResourceFieldsThroughComposeGo|upAcceptsDeployEndpointModeMetadataNormalizedByComposeGo|upRejectsUnsupportedDeployModesAsAppleContainerRuntimeGaps|runRejectsStartFirstDeployUpdatesAsAppleContainerRuntimeGaps'
python3 -m unittest Tools/release/test_update_homebrew_formula.py
bash -n Tools/parity/check-compose-deploy-endpoint-mode.sh
make docker-compose-deploy-endpoint-mode-parity
make docker-compose-cli-surface-parity
make check
make cli-smoke-built
make coverage-check
npx --yes markdownlint-cli2 README.md BUILD.md STATUS.md docs/bug-report-how-to.md docs/parity/compose-cli-surface.md docs/upstream/container-compose/ISSUE-deploy-endpoint-mode.md docs/upstream/container-compose/PR-deploy-endpoint-mode.md
git diff --check
```

## Compatibility

This change makes `container-compose` more permissive for Compose files that Docker Compose already accepts in local mode. It does not implement Docker Swarm VIP or DNSRR endpoint behavior for the Apple runtime.

## Remaining Risks

- If a future Apple runtime exposes explicit service endpoint-mode or source-aware DNS behavior, `container-compose` may need to preserve and project this metadata instead of accepting it as local no-op metadata.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `3caba0bbcd9aebc169b32e3f7228ffe18a6fb08b`.
