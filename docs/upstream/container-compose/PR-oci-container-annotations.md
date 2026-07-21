# Preserve Compose OCI annotations as distinct runtime metadata

## Summary

- Replace annotation-to-label collapsing with a distinct OCI annotation channel.
- Allow labels and annotations to use the same key with independent values.
- Extend the typed create-plan boundary so future direct API execution preserves annotations too.
- Pin the exact Apple-shaped `container` and `containerization` fork commits that implement the generic primitive.
- Add a checked-in Docker Compose YAML fixture and parity target that compare both normalized configurations and Compose dry-run runtime arguments.
- Update the status ledger without changing Compose command-help support levels.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | Generic OCI-spec annotations map only. |
| `apple/container` | Generic persisted `ContainerConfiguration.annotations` plus `container create/run --annotation key=value`. |
| `container-compose` | Compose-specific map validation and rendering; no fork-specific protocol or Docker Engine emulation. |

The lower forks remain independently useful on macOS and contain no Compose imports. Compose is the sole adapter from `services.<name>.annotations` to the generic primitive.

## Code map

- `Sources/ComposeCore/ComposeLabelHelpers.swift` keeps labels and annotations independent and removes the false conflict rule.
- `Sources/ComposeCore/ComposeOrchestratorRunCopyStart.swift` renders `--annotation` instead of `--label` for service annotations.
- `Sources/ComposeCore/ContainerServiceCreateAdapter.swift` and `ComposeOrchestratorConfigAndLinks.swift` preserve annotations through the typed create-plan abstraction.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` covers annotation rendering, same-key coexistence, one-off label overrides, and typed-plan preservation.
- `Tools/parity/fixtures/oci-annotations/compose.yaml` declares a same-key label/annotation fixture.
- `Tools/parity/check-compose-oci-annotations.sh` verifies Docker Compose V2 and `container-compose config --format json`, then asserts distinct dry-run arguments.
- `Makefile` exposes `make docker-compose-oci-annotations-parity`; `STATUS.md` marks the completed metadata gap accurately.

## Validation

```sh
make check
swift test --disable-automatic-resolution --filter ComposeOrchestratorTests --no-parallel
cd Tools/compose-normalizer && go test ./... -coverpkg=./... -coverprofile=coverage.out -covermode=atomic
make coverage-check
make docker-compose-oci-annotations-parity
```

Results on macOS:

- 843 focused Compose orchestration tests passed.
- The full coverage suite passed 1,102 Swift tests with 91.45% Swift coverage and 85.55% Go coverage, exceeding the repository's 90% and 85% gates.
- Docker Compose v5.3.1 and `container-compose` both preserve the fixture's separate maps; dry-run renders the expected `--label` and two `--annotation` arguments.
- Existing help metadata tests confirm `compose help` remains accurate; this feature adds no Compose CLI switch.

## Compatibility and risks

The change corrects a previously lossy mapping. Existing labels remain unchanged. Annotations now require the pinned generic runtime fork; stock Apple `container` lacks this primitive, so the existing compatibility preflight continues to reject an unmatched installation before runtime work begins.

## Commit tracking

- `containerization` generic OCI spec primitive: [`9109cbb8dab85917475f2ab3cecdbee797e2c0ad`](https://github.com/stephenlclarke/containerization/commit/9109cbb8dab85917475f2ab3cecdbee797e2c0ad), `feat(runtime): add OCI container annotations`.
- `container` generic resource/CLI/runtime adapter: [`9a75157a0c4ed1497bfb6b4ce8f43f6f1c25f0c8`](https://github.com/stephenlclarke/container/commit/9a75157a0c4ed1497bfb6b4ce8f43f6f1c25f0c8), `feat(runtime): add OCI container annotations`.
- `container-compose` adapter, tests, fixture, pins, and status ledger: [`eed2b309b8ce460b7eb4c07578a2a3b959e5f786`](https://github.com/stephenlclarke/container-compose/commit/eed2b309b8ce460b7eb4c07578a2a3b959e5f786), `feat(metadata): preserve OCI annotations`.
