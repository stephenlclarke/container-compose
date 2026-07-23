# Pull request: resolve the Phase 3 SonarQube findings

<!-- markdownlint-disable MD013 -->

## Summary

- Split `ComposeNetwork.Options` construction into a seven-parameter general
  initializer and a seven-parameter local-IPAM initializer that omits the
  mutually exclusive `external` option.
- Validate that image-volume subpaths are absolute and derive their filesystem
  root from the validated `FilePath` instead of embedding a path delimiter.
- Explain why the image-volume filesystem adapter has an intentionally empty
  initializer.
- Cover relative image-volume path rejection with a focused unit test.

## Commit and code map

Signed commit `ac2b81d8a6fc25f8f7a4012017c08a3c69140429`
(`fix(quality): resolve SonarQube findings`) is the reviewable implementation:

- `Sources/ComposeCore/NormalizedProject.swift` resolves
  `AZ-DxyNjCWx08sjElV_r` / `swift:S107` while encoding the existing rule that
  external networks cannot also declare local IPAM subnets.
- `Sources/ComposeContainerRuntime/ContainerImageVolumeFilesystemInitializer.swift`
  resolves `AZ-Cnr0wpUQsPE9ZuVqj` / `swift:S1075` and
  `AZ-CGyxNeOeLWQRAyQC5` / `swift:S1186` without changing the Apple runtime.
- `Tests/ComposeContainerRuntimeTests/ContainerImageVolumeFilesystemInitializerTests.swift`
  covers the new absolute-path invariant.

The change is intentionally confined to the Compose abstraction layer. It
adds no Windows behavior and requires no change in Apple's Container or
Containerization repositories.

## Local validation

The source-matched Compose gate on the designated Apple silicon MacBook Pro
passes the following pre-publication checks:

- 1,114 Swift tests in 26 suites.
- 91.39% Swift line coverage.
- 90.06% Go statement coverage.
- Focused image-volume suite: 9 tests.
- Focused Compose normalizer suite: 36 tests.
- Strict SwiftLint and SwiftFormat checks for the changed source and test files.
- Live Compose runtime: 25 of 25 scenarios passed.
- Docker Compose V2: 56 of 56 strict parity contracts passed against
  `docker compose` 5.3.1.

The live gates ran without a competing release job and used the source-matched
Builder, Containerization, and Container revisions recorded in the upstream
stack handoff. Exact-main hosted workflow, SonarCloud, Current, Homebrew,
checksum, and rendered-GIF evidence remain post-merge publication gates and
must identify the final documentation commit, not this source commit alone.

```sh
CONTAINER_BUILDER_SHIM_STACK_REPO=/path/to/container-builder-shim \
CONTAINERIZATION_STACK_REPO=/path/to/containerization \
CONTAINER_STACK_REPO=/path/to/container \
HOMEBREW_TAP_REPO=/path/to/homebrew-tap \
make ci swift-runtime-test docker-compose-parity
```

## Checklist

- [x] Signed Conventional source commit
- [x] Compose-layer-only implementation
- [x] Focused regression coverage
- [x] Complete unit and coverage gates
- [x] Clean 25-of-25 live runtime rerun
- [x] Clean 56-of-56 Docker Compose V2 parity rerun
- [ ] Signed Conventional documentation commit
- [ ] Exact-main hosted CI, Quality, CodeQL, and Documentation workflows
- [ ] Exact-main SonarCloud `OK` gate with zero unresolved issues
- [ ] Exact-main Current, Homebrew, checksum, and rendered-GIF verification
