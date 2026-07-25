# Pull request: resolve the Phase 5 SonarQube findings

## Summary

Replace the two single-case external-build-secret switches reported by
SonarCloud with equivalent pattern-matching conditionals. The code remains
entirely in the Compose layer, preserves every secret-lifetime invariant, and
does not require an Apple runtime change.

Review: [stephenlclarke/container-compose#146](https://github.com/stephenlclarke/container-compose/pull/146)

## Constructible commit

- `d6318ec967a4a01c014f7542eabeb11fade18cb8`
  `refactor(build): simplify external secret branches`

The implementation commit is signed and independently constructible. This
documentation commit is intentionally separate.

## Code map

- `Sources/ComposeCore/ComposeOrchestratorBuildSecrets.swift`
  - uses `if case let .external` while materializing live build secrets;
  - uses `if case .external` while projecting dry-run paths;
  - retains the existing normalization fallback for file and environment
    sources.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift`
  - existing focused tests cover live materialization, `0400` permissions,
    successful cleanup, cleanup after engine failure, dry-run behavior, and
    unavailable external resources;
  - the ordinary build test covers file and environment fallback.

## Verification

```sh
swift test --filter \
  'ComposeCoreTests\.ComposeOrchestratorTests/build(MaterializesExternalSecretsOnlyForEngineInvocation|RemovesExternalSecretFilesAfterEngineFailure|DryRunNeitherReadsNorWritesExternalSecrets)'
make check
git diff --check
```

Focused verification passed locally with three tests in one suite.
`make check` also passed, including 167 release-controller tests, 14 CI-helper
tests, coverage policy, stack consistency, release consistency, and
credential scanning. Hosted checks, the exact-revision Sonar result, Current
publication, and live Docker Compose v2 parity are promotion requirements and
will be recorded here before the phase handoff.

## Compatibility and risk

The refactor changes control-flow spelling only. It does not change normalized
Compose data, filesystem paths, secure-store reads, secret contents,
permissions, cleanup, engine arguments, or dry-run output. The stable
`0.10.0` artifacts remain immutable. No Apple-facing pull request is required.

## Review checklist

- [x] The signed implementation commit is identified.
- [x] Live and dry-run external-secret branches retain focused unit coverage.
- [x] File and environment fallback behavior remains covered.
- [x] Complete local quality gate passes.
- [ ] Hosted CI and CodeQL pass for the exact revision.
- [ ] Exact-revision SonarCloud quality gate passes with zero open issues.
- [ ] Current prerelease and Docker Compose v2 parity are verified.
