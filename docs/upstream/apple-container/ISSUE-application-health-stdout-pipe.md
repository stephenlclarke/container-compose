# Application-health tests can block on an unread stdout pipe

## Problem

Two fallback-help tests replace process-wide stdout with a pipe across an
`await`, but do not read from that pipe until the operation returns. If it
fills, the operation cannot return. Because descriptor 1 is global, unrelated
concurrent output can also be captured.

The tests only assert that fallback help completes while plugin discovery is
unavailable. Output suppression is not part of the behavior under test.

## Required behavior

- Run the two help commands directly under their existing two-second wall-time
  guard.
- Delete the unread-pipe helper and its unused Darwin import.
- Do not change production code, CLI output, or Compose behavior.
- Do not carry the obsolete Makefile edit from fork PR
  [#6](https://github.com/stephenlclarke/container/pull/6); current `main`
  intentionally uses `build-tests` plus `--skip-build` for integration.

## Validation

- Five consecutive focused runs passed 75 tests in total.
- `make coverage-unit` passed 1,131 instrumented unit tests in 131 suites and
  regenerated the unit report at 38.69% line coverage.
- `make check` passed.
- The complete source-build integration gate passed 3 warmup, 238 concurrent,
  and 143 serial tests with the simplified test compiled into the suite.

## Commit tracking

- `659a01733ac03c07624b545fb552f1536f80b203`
  (`test(health): avoid unread stdout pipe`)
