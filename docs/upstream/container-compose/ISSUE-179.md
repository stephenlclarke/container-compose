# PR 179: exact-main Sonar analysis retains maintainability findings

## Problem

The exact-main SonarCloud analysis for merge commit
`ea9a1ceffdae517fc96c1a514be3064fddaf5840` passed its quality gate but
reported 14 open code smells. The findings covered duplicated archive path
normalization, wide public initializers, an unused parameter pair, an empty
completion-drain body, a stateless empty initializer, a reserved-word static
property, a hard-coded shell path, and one Go helper above the configured
cognitive-complexity limit.

Leaving these findings open would make the quality gate green without meeting
the project's zero-debt acceptance criterion.

## Reproduction

1. Open the SonarCloud analysis for revision
   `ea9a1ceffdae517fc96c1a514be3064fddaf5840`.
2. Confirm that the quality gate is `OK`.
3. Query open issues for project `stephenlclarke_container-compose2`.
4. Observe 14 open maintainability findings.

## Resolution

- Centralize Compose archive source normalization in `ComposeArchivePath`.
- Group commit-image metadata and extended process options into typed option
  values while retaining the existing flat encoded process representation and
  deprecated source-compatible forwarding APIs.
- Remove unused inline-Dockerfile parameters.
- Give stateless and concurrent completion paths explicit intent.
- Rename the default log configuration to `standard`.
- Extract Go network-alias insertion into a small deterministic helper.
- Add focused archive-path regression tests and retain runtime projection
  coverage.

## Acceptance

- The complete local Swift and Go test gate passes.
- SwiftLint, SwiftFormat, Go formatting, repository policy checks, strict
  upstream-divergence checks, and the release build pass.
- Pull-request CI passes.
- A new exact-main SonarCloud analysis reports an `OK` quality gate and zero
  unresolved issues. The two wide compatibility initializers and reserved-name
  logging alias are explicitly accepted as public API constraints rather than
  hidden with source or project-rule suppressions.
- CodeQL remains manually disabled until the repository owner requests that it
  be re-enabled.

## Compatibility

The refactor changes no Compose command behavior, Docker parity semantics,
runtime wire shape, or Apple runtime dependency. The grouped option values are
construction-time API cleanup; deprecated forwarding properties, initializers,
and the logging `default` alias preserve the prior public source surface. Stored
process fields and their `Codable` representation remain flat. The forwarding
surface is retained until the next explicitly breaking major release.
