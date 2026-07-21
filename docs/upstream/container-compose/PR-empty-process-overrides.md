# Preserve explicit empty Compose process overrides

## Summary

- Preserve explicit empty `command: []` and `entrypoint: []` arrays across the compose-go-to-Swift JSON boundary.
- Map only `entrypoint: []` to the generic lower-runtime `--clear-entrypoint` option; a non-empty entrypoint keeps the existing executable/prefix mapping.
- Add unit coverage for the Go normalizer, Swift model decoder, runtime argument projection, and the lower `container` process parser.
- Add a Docker Compose v5.3.1 YAML/Dockerfile parity fixture that proves the image command runs after an image entrypoint is cleared.
- Update the Phase 4 status ledger to remove this completed adapter/runtime gap without changing Compose help support levels.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | No change. |
| `apple/container` | Generic `--clear-entrypoint` process-resolution option; no Compose dependency. |
| `container-compose` | Preserve Compose empty arrays and render the generic option only for an empty entrypoint. |

This keeps OCI process policy below the Compose layer while avoiding a Docker-shaped API or a Compose-specific fork change.

## Code map

- `Tools/compose-normalizer/main.go` uses optional slices so JSON can distinguish omitted fields from explicit `[]` values.
- `Sources/ComposeCore/ComposeOrchestratorRunCopyStart.swift` projects an empty entrypoint into `--clear-entrypoint`.
- `Tools/parity/fixtures/empty-process-overrides/` contains an image with a deliberately failing inherited entrypoint and a successful retained command.
- `Tools/parity/check-compose-empty-process-overrides.sh` compares Docker Compose V2 config/runtime behavior and runs the matching Apple-runtime assertion only in the isolated live lane.
- `STATUS.md` records the completed process-override mapping and leaves unrelated annotations, `expose`, lifecycle-state, and events gaps intact.

## Validation

```sh
cd Tools/compose-normalizer && go test ./... -coverpkg=./... -coverprofile=coverage.out -covermode=atomic
swift test --disable-automatic-resolution --filter ComposeNormalizerTests --no-parallel
swift test --disable-automatic-resolution --filter EmptyEntrypoint --no-parallel
make docker-compose-empty-process-overrides-parity
```

The Docker reference is pinned to Compose v5.3.1. The fixture asserts both normalized JSON values and an exit-zero runtime command after clearing an image `ENTRYPOINT ["/bin/false"]`.

## Compatibility and risks

The behavior is additive for a previously lost Compose form. Omitted and non-empty process fields retain their existing mapping. A live macOS assertion requires the matching fork release because stock Apple `container` does not expose this generic primitive.

## Commit tracking

- Required `container` fork commit: [`93505008b130822065b89a6c5d610b9b6fa80122`](https://github.com/stephenlclarke/container/commit/93505008b130822065b89a6c5d610b9b6fa80122), `feat(process): clear image entrypoint`; pinned in `Package.swift`, `Package.resolved`, and `Tools/release/stack-refs.json`.
- `container-compose` integration commit: the signed `feat(process): preserve empty Compose overrides` commit that adds this handoff and its code map.
- No `containerization` commit is required.
