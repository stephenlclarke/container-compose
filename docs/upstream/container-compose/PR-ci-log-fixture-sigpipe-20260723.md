# Pull request handoff: keep followed-log fixtures from raising SIGPIPE

## Proposed title

`test(ci): prevent followed-log fixture SIGPIPE`

## Summary

Make the macOS followed-log test fixture convert writes to a closed pipe into
ordinary write errors instead of terminating `swiftpm-testing-helper`.

The production log adapter is unchanged. The fix is descriptor-local and
applies only to test-owned raw and structured stream writers.

## Root cause

`FileHandle.write(contentsOf:)` cannot catch a Darwin `SIGPIPE` delivered
before the write returns. The rotating fixture retains detached writers so it
can model runtime log chunks; a reader can close while one of those writers is
still delayed.

The hosted coverage run retried three times and exited with signal 13 at the
same followed-log fixture boundary.

## Code map

- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift`
  - sets `F_SETNOSIGPIPE` on each test pipe writer;
  - covers both raw and structured followed-log streams;
  - adds a closed-reader/delayed-writer regression.
- `docs/upstream/container-compose/ISSUE-ci-log-fixture-sigpipe-20260723.md`
  - records the hosted reproduction and acceptance criteria.
- `docs/upstream/container-compose/PR-ci-log-fixture-sigpipe-20260723.md`
  - supplies this review handoff.

## Commit

Apply the signed source commit:

```text
682e173 test(ci): prevent followed-log fixture SIGPIPE
```

Apply the signed documentation commit:

```text
docs(ci): hand off followed-log SIGPIPE fix
```

## Validation

```bash
swift test --filter rotatingLogFixtureToleratesClosedReader
make coverage-check
make check
```

Expected results:

- the delayed write after reader closure does not terminate the process;
- all Swift and Go tests pass;
- coverage remains above the repository thresholds;
- source, policy, and documentation checks pass.

## Compatibility and risk

`F_SETNOSIGPIPE` changes only the selected fixture descriptor. It does not
alter process-wide signal handling and cannot hide signals from production
code or unrelated tests.

The non-Darwin branch is a no-op because this task supports the macOS runtime.

## Rollback

Reverting the source commit restores the prior fixture behavior and the hosted
signal-13 failure. Do not replace this with process-wide `SIG_IGN`, which would
affect unrelated tests.

## PR template

### Type of change

- [x] Test reliability
- [x] Hosted CI repair
- [x] macOS-specific descriptor handling
- [ ] Production behavior
- [ ] Breaking change

### Testing

- [x] Focused closed-reader regression
- [x] Full local coverage gate
- [x] Source and documentation checks
- [ ] Hosted CI and SonarQube
- [ ] Exact Current package and VHS

Related issue handoff:
`docs/upstream/container-compose/ISSUE-ci-log-fixture-sigpipe-20260723.md`.
