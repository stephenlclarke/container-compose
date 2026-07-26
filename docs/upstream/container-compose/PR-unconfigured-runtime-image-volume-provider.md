# Pull request: fail closed without an image-volume runtime provider

## Summary

- Make unconfigured image-volume metadata preparation and declared-volume
  lookup report the existing explicit provider error.
- Cover all 38 concrete operations on the public unconfigured provider.
- Prove declared-volume planning stops before any resource can be created.
- Replace test reliance on the former fail-open behavior with an explicit
  no-declared-volume provider.

## Intended review delta

Apply signed commit
[`5d5327904ee38d0db7ad8faddbbd8fd448750abc`](https://github.com/stephenlclarke/container-compose/commit/5d5327904ee38d0db7ad8faddbbd8fd448750abc),
`fix(runtime): fail closed for image volume metadata`.

The change is confined to the Compose default-provider boundary and test
fixtures. It requires no Apple runtime change and introduces no Windows or
Linux-host branch. See the companion
[issue handoff](ISSUE-unconfigured-runtime-image-volume-provider.md).

## Code map

- `ComposeUnconfiguredRuntime.prepareImageVolumeMetadata` throws the
  established image-metadata provider error.
- `ComposeUnconfiguredRuntime.imageDeclaredVolumeTargets` throws the same
  error instead of returning an authoritative empty list.
- `ComposeRuntimeProviderDefaultsTests` exercises copying, export, exec,
  events, lifecycle, inspection, external content, discovery, images,
  image-volume initialization, and resources.
- `ComposeOrchestratorTestRuntime` supplies an explicit no-volume image
  provider to command-oriented orchestration fixtures.

## Validation

```console
swift test --filter ComposeRuntimeProviderDefaultsTests
make coverage-check
CONTAINER_RUNTIME_INIT_BLOCK_REPO=/absolute/path/to/container \
CONTAINERIZATION_INIT_SOURCE_PATH=/absolute/path/to/containerization \
CONTAINER_COMPOSE_INIT_IMAGE=vminit:container-compose-provider \
make CONTAINER_COMPOSE_LIVE=1 docker-compose-image-volumes-parity
```

Results on the designated Apple silicon MacBook Pro:

- focused provider contract: 7 tests, all green;
- complete Swift gate: 1,224 tests in 41 suites, all green;
- Swift line coverage: 92.66%;
- Go statement coverage: 89.88%;
- strict Docker Compose V2 local-volume parity: passed;
- source-matched Apple runtime local-volume and subpath lifecycle: passed;
- SwiftFormat and strict SwiftLint on every changed Swift file: passed.

The live Apple leg used `stephenlclarke/container` at `221fafc24ebd19502f4553e0b5d38c14be3f2b22`,
`stephenlclarke/containerization` at
`164088e02e16ed80e536d0c59822b09931d213df`, and a guest init image built from
that Containerization source.

The installed runtime's stock `vminit:0.38.0` does not understand the fork's
new volume-subpath source field. Its direct subpath failure is host/guest
version skew, not a failure of this Compose change; the documented
source-matched harness is the valid fork integration gate.

## Compatibility and risk

- Configured providers are unchanged.
- Missing providers now fail before side effects instead of silently producing
  an incomplete plan.
- Test-only no-volume metadata is explicit and cannot enter production code.
- No new Apple runtime dependency is introduced into `ComposeCore`.

## Checklist

- [x] Signed Conventional implementation commit
- [x] Compose-layer-only production change
- [x] Contract and planner regression coverage
- [x] Complete coverage gate
- [x] Docker Compose V2 and source-matched Apple runtime parity
- [x] Signed Conventional documentation commit
- [ ] Pull-request checks and connector review
- [ ] Exact-main CI, CodeQL, and SonarCloud gate
- [ ] Slice prerelease, checksums, attestations, and Homebrew update
