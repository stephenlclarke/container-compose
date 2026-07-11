# Accept Compose `build.isolation`

## Summary

- Stops reporting `services.<name>.build.isolation` as an unsupported build field.
- Keeps the normalized `ComposeBuild.isolation` value available for config output and future platform-specific handling.
- Keeps `build --print` Docker-compatible by omitting isolation from generated Buildx bake JSON on this platform.
- Adds focused Go and Swift tests for the normalized/accepted behavior.
- Adds a local-only Docker Compose parity target for the CLI/config/build-print surface.
- Updates README, status, parity docs, and contributor build docs.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose V2 accepts Compose file `build.isolation` values even when the local Buildx path does not project the setting into bake JSON. `container-compose` already preserved the value but rejected non-default values as unsupported, which made otherwise Docker-compatible Compose files fail before build orchestration.

The upstream review signal is that `build.isolation` is a Compose-spec field and Docker Compose fixed classic-builder handling separately from Buildx bake rendering. Because the stephenlclarke fork-backed build path is BuildKit-oriented, this slice mirrors Docker Compose's Buildx behavior instead of adding an Apple runtime primitive.

## Implementation Details

- Removed `build.isolation` from `unsupportedBuildFields` in `Tools/compose-normalizer/main.go`.
- Left the normalized `isolation` field in the Swift model so `config --format json` keeps reporting the Compose value.
- Left `container build` command rendering unchanged; there is no new `--isolation` forwarding.
- Added `Tools/parity/check-compose-build-isolation.sh` plus `make docker-compose-build-isolation-parity`.
- Updated `Tools/release/update-homebrew-formula.py` so prebuilt package publication also refreshes the formula's `container-compose version --short` assertion.

## Validation

```sh
gh search issues "build.isolation" --repo docker/compose --repo compose-spec/compose-go --repo compose-spec/compose-spec --repo docker/buildx --repo moby/buildkit --limit 20
gh search prs "build.isolation" --repo docker/compose --repo compose-spec/compose-go --repo compose-spec/compose-spec --repo docker/buildx --repo moby/buildkit --limit 20
gh issue view 10056 --repo docker/compose --comments
gh pr view 78 --repo compose-spec/compose-spec --comments --json title,state,mergedAt,url,body,files
docker-compose -f compose.yml config --format json
docker-compose -f compose.yml build --print api
docker-compose -f compose.yml build api
go test ./...
python3 -m unittest Tools/release/test_update_homebrew_formula.py
swift test --disable-automatic-resolution --filter 'ComposeNormalizerTests|upRejectsUnmappedBuildFieldsBeforeCreatingResources|runRejectsUnmappedBuildFieldsBeforeCreatingResources|buildRejectsUnsupportedBuildFieldsBeforeEmittingCommands'
bash -n Tools/parity/check-compose-build-isolation.sh
make docker-compose-build-isolation-parity
make docker-compose-cli-surface-parity
make check
make cli-smoke-built
make coverage-check
git diff --check
```

## Compatibility

This change makes `container-compose` more permissive for Docker Compose files that already parse under Compose V2. It does not claim a Windows container isolation effect on macOS/Linux or add an Apple runtime flag. Service-level `isolation` remains blocked until a matching runtime primitive exists.

## Remaining Risks

- If a future Apple or BuildKit backend grows a real platform-specific isolation control, `container-compose` may need to decide whether to forward `build.isolation` for that backend.
- Docker Compose behavior may differ on native Windows builders where classic builder isolation has an observable effect.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `01b6b3425a1c3e522918cda43e9fac263de07e4a`.
