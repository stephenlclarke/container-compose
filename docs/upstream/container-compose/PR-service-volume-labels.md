# Support service long-form volume labels

## Summary

- Preserves service long-form `volume.labels` in the normalized mount model.
- Stops treating `volume.labels` as an unsupported mount field while keeping `volume.subpath` blocked.
- Creates deterministic labeled anonymous volumes before Apple runtime create/run handoff.
- Keeps named service mount labels as config metadata, matching Docker Compose runtime behavior.
- Adds focused Go normalizer and Swift orchestration coverage.
- Adds a local-only Docker Compose parity target for service volume labels.
- Bumps the plugin release line to `0.4.1` (`0.4.0` feature work plus the Sonar-clean patch).
- Updates README, status, parity/build docs, and release metadata.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose accepts service long-form `volume.labels` and preserves those labels in `config --format json`. Runtime parity is subtle: Docker applies those labels to anonymous volumes, but named service mount labels do not change the named volume resource; named volume resource labels still come from top-level `volumes.<name>.labels`.

Before this change, `container-compose` rejected every service mount using `volume.labels`. The Stephen runtime lane already supports labeled volume creation through the fork-backed Apple/container volume APIs, so this can be fixed inside the plugin without changing Apple/container.

Upstream review found no direct Docker/Compose issues or PRs for service `volume.labels`. Apple/container has already merged the relevant volume primitives in `apple/container#768` and `apple/container#769`; the older Compose plugin proposal in `apple/container#398` confirms this belongs in the Compose plugin layer.

## Implementation Details

- Added `volumeLabels` to the Go normalizer JSON and Swift `ComposeMount`.
- Added `volumeLabelsValue` in the normalizer to preserve compose-go service volume labels.
- Removed `volume.labels` from unsupported mount-field reporting while leaving `volume.subpath` unsupported.
- Added `ensureLabeledAnonymousVolumes` so `up`, `create`, and `run` create labeled anonymous volumes before rendering the container command.
- Creates labeled anonymous volumes after `--renew-anon-volumes` cleanup so renewed containers do not lose labels.
- Does not merge named service mount labels into named `volume create`; top-level volume labels remain the resource label source.
- Added `Tools/parity/check-compose-volume-labels.sh` and `make docker-compose-volume-labels-parity`.

## Validation

```sh
gh search issues --repo docker/compose 'volume.labels' --limit 20 --json number,title,state,url,updatedAt
gh search issues --repo compose-spec/compose-spec 'volume.labels' --limit 20 --json number,title,state,url,updatedAt
gh search issues --repo compose-spec/compose-go 'volume labels' --limit 20 --json number,title,state,url,updatedAt
gh search issues --repo apple/container 'volume label' --limit 20 --json number,title,state,url,updatedAt
gh search prs --repo apple/container 'volume label' --limit 20 --json number,title,state,url,updatedAt
gh search prs --repo apple/container 'anonymous volume' --limit 20 --json number,title,state,url,updatedAt
go test ./...
go test ./... -cover
swift test --filter 'ComposeCoreTests.ComposeNormalizerTests/normalizesComposeFileThroughComposeGo|ComposeCoreTests.ComposeOrchestratorTests/upKeepsNamedServiceVolumeLabelsOutOfVolumeCreate|ComposeCoreTests.ComposeOrchestratorTests/upCreatesLabeledAnonymousVolumesBeforeContainerCreate|ComposeCoreTests.ComposeOrchestratorTests/upDryRunRendersLabeledAnonymousVolumeCreate|ComposeCoreTests.ComposeOrchestratorTests/runCreatesLabeledAnonymousVolumesBeforeOneOffContainer'
bash -n Tools/parity/check-compose-volume-labels.sh
shellcheck Tools/parity/check-compose-volume-labels.sh
make docker-compose-volume-labels-parity
make check
make cli-smoke-built
make coverage-check
SONAR_QUALITYGATE_WAIT=true make sonar-scan
git diff --check
```

## Compatibility

This change makes `container-compose` more Docker Compose compatible for service volume metadata. Compose files that use `volume.labels` now load and run instead of failing early. Anonymous runtime volumes receive user labels before container creation; named service mount labels stay metadata so the plugin does not create labels Docker Compose would omit from named volume resources.

## Remaining Risks

- Docker Compose may eventually define additional runtime effects for named service mount labels. The current implementation follows Docker Compose 5.2.0 behavior observed locally.
- The plugin uses deterministic anonymous volume names rather than Docker's random anonymous volume names, matching the existing `container-compose` cleanup model.
- `volume.subpath` remains blocked until Apple/container exposes compatible subpath mount behavior.
