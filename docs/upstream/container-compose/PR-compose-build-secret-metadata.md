# Accept ignored Compose build secret metadata

## Summary

- Stops reporting file/env-backed `build.secrets` as unsupported solely because the long syntax includes `uid`, `gid`, or `mode`.
- Keeps the effective BuildKit secret projection unchanged: `id` plus file/env source only.
- Adds focused Go and Swift normalizer coverage for metadata-bearing build secrets.
- Adds a local-only Docker Compose parity target for config/build-print/build behavior.
- Updates README, status, parity docs, and contributor build docs.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose V2 accepts build secret `uid`, `gid`, and `mode` metadata, but BuildKit does not implement those fields. Docker Compose preserves the metadata in config output, omits it from bake secret entries, and still accepts the build. `container-compose` previously rejected these Compose files before build orchestration.

The upstream review signal is clear: Docker Compose issue `docker/compose#10704` and merged PR `docker/compose#10709` document that these fields are ignored rather than implemented. Because the stephenlclarke fork-backed build path is BuildKit-oriented, this slice mirrors Docker Compose's build behavior without adding any Apple runtime surface.

## Implementation Details

- Removed the normalizer's unsupported check for build-secret `uid`, `gid`, and `mode`.
- Left build secret command rendering unchanged so `container build --secret` receives only the effective BuildKit id and file/env source.
- Added `Tools/parity/check-compose-build-secret-metadata.sh` plus `make docker-compose-build-secret-metadata-parity`.
- Kept non-file/env build secret definitions rejected as unsupported.

## Validation

```sh
gh search issues "build secrets uid gid mode" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo docker/buildx --repo moby/buildkit --limit 20
gh search prs "build secrets uid gid mode" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo docker/buildx --repo moby/buildkit --limit 20
gh api graphql -f query='query($q:String!){ search(query:$q, type:DISCUSSION, first:10){ nodes { ... on Discussion { title url createdAt updatedAt repository { nameWithOwner } } } } }' -f q='build secrets uid gid mode repo:docker/compose repo:compose-spec/compose-spec repo:docker/buildx repo:moby/buildkit'
gh issue view 10704 --repo docker/compose --comments
gh pr view 10709 --repo docker/compose --comments --json title,state,mergedAt,url,body,files,comments
docker-compose -f compose.yml config --format json
docker-compose -f compose.yml build --print api
docker-compose -f compose.yml build api
go test ./...
swift test --disable-automatic-resolution --filter 'normalizesSupportedBuildSecretsThroughComposeGo|upRejectsUnmappedBuildFieldsBeforeCreatingResources|runRejectsUnmappedBuildFieldsBeforeCreatingResources|buildRejectsUnsupportedBuildFieldsBeforeEmittingCommands'
bash -n Tools/parity/check-compose-build-secret-metadata.sh
make docker-compose-build-secret-metadata-parity
make docker-compose-cli-surface-parity
make check
make cli-smoke-built
make coverage-check
git diff --check
```

## Compatibility

This change makes `container-compose` more permissive for Docker Compose files that already parse and build under Docker Compose V2. It does not claim that build-secret ownership or permissions are honored by BuildKit. Service runtime secrets keep their existing behavior: generated runtime secret grants can apply mode locally, while generated runtime uid/gid ownership remapping remains unsupported.

## Remaining Risks

- If BuildKit later adds secret ownership or permission fields, `container-compose` may need to forward the metadata through a newer build backend.
- `container-compose config` reports normalized effective build secrets rather than Docker Compose's raw long-syntax secret grant objects.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `082d5f1f956eff0dac0c13361d4ddfdea7abd923`.
