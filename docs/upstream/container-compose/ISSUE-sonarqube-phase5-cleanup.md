# Resolve the Phase 5 SonarQube findings

## Problem

The exact `main` SonarCloud analysis for Phase 5 release-control commit
`caa6ce5b595073521c03ab7ae0abc87a84e6e257` passed its quality gate, but
reported two open `swift:S1301` maintainability findings in
`ComposeOrchestratorBuildSecrets.swift`. Both findings identify a `switch`
whose only specialized branch handles an external build secret and whose
fallback handles every non-external source.

The branches are already owned by the Compose layer and have complete behavior
coverage for live materialization, file and environment fallback, failed-build
cleanup, and dry-run projection. No Apple runtime primitive or fork change is
needed.

## Acceptance criteria

- Replace each single-case `switch` with a behavior-equivalent conditional.
- Keep external secret bytes invocation-private and preserve `0400`
  permissions, cleanup, dry-run behavior, and normalized non-external sources.
- Keep the change in `ComposeCore`; do not change a public model, SPI, runtime
  fork, or command-line surface.
- Pass the focused external-build-secret tests and the complete local quality
  gate.
- Pass exact-revision hosted CI, CodeQL, and SonarCloud with no unresolved
  Sonar issues.
- Publish and verify the exact-revision Current prerelease before Phase 6.

## Implementation

Signed commit `d6318ec967a4a01c014f7542eabeb11fade18cb8`
(`refactor(build): simplify external secret branches`) contains the two
Compose-only refactors. The paired pull-request handoff records the code map,
tests, and post-merge evidence. Pull request
[#146](https://github.com/stephenlclarke/container-compose/pull/146) merged the
change; exact `main` revision
`b644c71fd0f7dd665a2a74192ab55745faafa281` passed SonarCloud with zero open
issues and was published through the verified
[`current` release](https://github.com/stephenlclarke/container-compose/releases/tag/current).

## Compatibility

This is a source-equivalent maintainability refactor. The Docker Compose v2
external-build-secret parity contract and the stable `0.10.0` release remain
unchanged. No Apple-facing pull request is required.
