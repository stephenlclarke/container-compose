# Pull request handoff: follow Apple's Builder suite rename

## Summary

Keep the narrowly bounded pre-Phase-5 Builder-gap exception valid after
apple/container#2002 renamed and parallelized the affected integration suites.
The release gate excludes the same three tests by their current upstream names
and leaves every other concurrent and serial suite enabled.

## Minimal integration boundary

- Changes no Compose or Container runtime behavior.
- Changes no hosted release validation.
- Does not add or remove a deferred Phase 5 capability.
- Replaces the old serial-suite override with the current upstream concurrent
  suite override.
- Preserves fail-closed filename checks and the `0.10.0` expiry.

## Code map

- `Tools/ci/run-stack-release-validation.sh`
  - recognizes the three renamed suites;
  - derives the remaining concurrent suite filter;
  - passes `CONCURRENT_TEST_SUITES` without changing serial coverage.
- `Tools/release/test_container_stack_release.py`
  - proves the exact new filter;
  - proves a missing tracked suite still fails closed;
  - retains hosted-mode rejection coverage.
- `BUILD.md`
  - documents the upstream rename and unchanged policy boundary.
- `docs/upstream/container-compose/ISSUE-phase4-builder-exception-upstream-rename.md`
  - records the cause, reproduction, scope, and expected behavior.

## PR template

### Type of change

- [x] Release-gate compatibility
- [x] Test update
- [x] Documentation update
- [ ] Runtime feature
- [ ] Breaking change

### Motivation and context

The signed Apple upstream sync removed
`TestCLIBuilderSerial.swift`,
`TestCLIBuilderLocalOutputSerial.swift`, and
`TestCLIBuilderTarExportSerial.swift` after moving those tests into concurrent
suites. The bounded pre-Phase-5 exception must follow the current upstream
names so Phase 4 can release without concealing any additional integration
coverage.

### Testing

- [x] Exact policy unit tests
- [x] Missing-suite fail-closed test
- [x] Hosted-mode rejection test
- [x] Full Compose check
- [ ] Exact Current and stable release gates

### Reviewer notes

Review the release validation script as the complete behavioral boundary. The
filter remains restricted to `TestCLIBuilder`, `TestCLIBuilderLocalOutput`, and
`TestCLIBuilderTarExport`; Phase 5 still owns their runtime fixes and removes
this exception.

## Commit tracking

- Container upstream rename:
  `d1d763530df3c6a326dbae7f0c0a59a335808045`.
- Container fork reconciliation:
  `abed15fdd0cafe340f8aceb65080e4a88d0ceb0a`.
- Compose release-gate commit:
  `b99c3163d20c47f710d3d3e91ca186d221190387`.
