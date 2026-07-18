# Pull request: project Compose Deploy memory reservations

## Summary

- Map `deploy.resources.reservations.memory` into the existing normalized
  `memReservation` field.
- Reuse the existing typed service-create plan and generic
  `container create/run --memory-reservation` bridge.
- Retain Deploy CPU reservation strictly as local scheduler metadata, matching
  Docker Compose V2 local mode.
- Add Go and Swift unit coverage plus a Docker Compose V2 configuration and
  dry-run parity assertion.
- Refresh the parity ledger and command HELP markers so the documented support
  status matches behavior.

## Apple-shaped implementation boundary

There is no new fork change in this PR. The Compose-layer projection is the
smallest upstreamable delta because the generic memory-reservation primitive
already exists below it:

| Repository | Existing prerequisite | Required delta |
| --- | --- | --- |
| `stephenlclarke/containerization` | `c5ca0366d88cf77eefb857b7b3d7f2d098070bab` | None |
| `stephenlclarke/container` | `d5774583697dc239b140ae38cc79fa9259753061` | None |
| `stephenlclarke/container-compose` | Existing `mem_reservation` runtime adapter | Normalize the Deploy alias into that adapter |

The new code is limited to:

- `Tools/compose-normalizer/main.go`: `deployReservationMemory` and the
  `MemReservation` normalization fallback;
- `Tools/compose-normalizer/main_test.go`: normalizer branches and byte-value
  projection;
- `Tests/ComposeCoreTests/ComposeNormalizerTests.swift` and
  `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift`: normalized model and
  runtime command-vector coverage;
- `Tools/parity/check-compose-deploy-resource-reservations.sh`: Docker Compose
  V2 fixture/config parity and Engine-backed dry-run confirmation when a local
  Docker daemon is available.

This avoids a Compose-specific API in either Apple-shaped fork and preserves a
single generic runtime resource abstraction.

## Docker Compose V2 parity contract

For this fixture:

```yaml
services:
  api:
    image: alpine:3.20
    deploy:
      resources:
        reservations:
          cpus: "0.25"
          memory: 32M
```

- Docker Compose preserves both reservation values in `config --format json`.
- Docker Compose local creation uses memory as its soft-reservation resource;
  CPU reservation is not a local Engine CPU reservation.
- `container-compose config --format json` emits
  `memReservation: "33554432"` and does not report either accepted field as an
  unsupported Deploy field.
- `container-compose --dry-run up` contains
  `--memory-reservation 33554432`.

## Validation

```sh
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter \
  'normalizesDeployResourceLimitsThroughComposeGo|upProjectsDeployMemoryReservationsWhileRetainingCPUReservationMetadata'
bash -n Tools/parity/check-compose-deploy-resource-reservations.sh
make docker-compose-deploy-resource-reservations-parity
make ci
make docker-compose-parity
markdownlint $(git ls-files '*.md')
git diff --check
```

## Non-goals

- Fractional CPU quota/reservation, CPU period/quota/realtime controls, and
  byte-accurate hard memory limits require lower runtime support.
- Deploy pids, generic-resource, and non-GPU device reservations remain
  scheduler/runtime gaps.
- Windows-only Compose attributes are intentionally outside this macOS scope.

## Commit tracking

The implementation commit is recorded in this document by the immediately
following handoff-linkage commit after this slice is validated. The linked
commit carries the exact `container-compose` code and tests above; no Apple
fork commit is required for this change.
