# Resolve the Phase 3 SonarQube findings

<!-- markdownlint-disable MD013 -->

## Context

The Phase 3 release gate must have no unresolved SonarQube issue before the
Current prerelease can begin its seven-day soak. SonarCloud reported three
code-smell findings against `stephenlclarke_container-compose2`:

- `AZ-DxyNjCWx08sjElV_r` / `swift:S107` in
  `Sources/ComposeCore/NormalizedProject.swift`: the network-options
  initializer exposed eight parameters.
- `AZ-Cnr0wpUQsPE9ZuVqj` / `swift:S1075` in
  `Sources/ComposeContainerRuntime/ContainerImageVolumeFilesystemInitializer.swift`:
  the image-volume initializer used a hard-coded root delimiter.
- `AZ-CGyxNeOeLWQRAyQC5` / `swift:S1186` in the same runtime adapter: its
  intentionally empty initializer had no explanation.

## Required behavior

- Preserve all existing external-network and locally managed network
  normalization behavior without an eight-parameter initializer.
- Derive the image-volume filesystem root from the validated absolute image
  subpath; reject relative image-volume paths before mounting.
- Keep the runtime adapter stateless and document why construction performs no
  work.
- Keep the implementation in the Compose layer and make no Apple runtime fork
  change.

## Acceptance criteria

- The focused image-volume and Compose normalizer suites pass.
- The complete Compose unit and coverage gates pass.
- All 25 live Compose runtime scenarios pass on the designated Apple silicon
  MacBook Pro against the source-matched Apple runtime stack.
- All 56 strict Docker Compose V2 contracts pass against the documented Docker
  Compose version.
- Exact-main hosted CI, Quality, CodeQL, and Documentation workflows pass.
- The exact-main SonarCloud analysis has an `OK` quality gate and zero
  unresolved issues.
- The Current prerelease, Homebrew formulae, checksums, and rendered README GIF
  all identify the same immutable main commit.

## Implementation reference

Signed commit `ac2b81d8a6fc25f8f7a4012017c08a3c69140429`
(`fix(quality): resolve SonarQube findings`) contains the source and regression
test changes. The paired pull-request handoff maps each finding to its code and
records the validation and publication gates.
