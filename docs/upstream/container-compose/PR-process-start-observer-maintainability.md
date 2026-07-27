# Pull request: isolate process start observation

## Summary

- Extract the launch-race callback contract into `ProcessStartObserver`.
- Invoke that observer through one private helper instead of nesting closure
  expressions inside task-cancellation continuations.
- Explain why the production observer intentionally does nothing.
- Preserve process launch, cancellation, job-control, and test-hook behavior.

## Intended review delta

Apply signed implementation commit
[`7939874a8fd0dc29097a871c92f319a8f25de402`](https://github.com/stephenlclarke/container-compose/commit/7939874a8fd0dc29097a871c92f319a8f25de402)
and its documentation commit from the
`fix/process-start-observer-maintainability` branch. The implementation changes
one private ComposeCore file and no public API. See the companion
[issue handoff](ISSUE-process-start-observer-maintainability.md).

## Code map

- `ProcessStartObserver` names the private callback shape.
- `notifyProcessDidStart` owns the callback closure and forwards cancellation
  to the invocation's `ProcessRunState`.
- The prompt-inheriting and inherited-I/O continuations call the helper without
  another nested closure.
- The production initializer retains its no-op observer and documents why only
  tests install a callback.

## Validation

```console
swift test --disable-automatic-resolution --filter ProcessRunner
swift test --disable-automatic-resolution --sanitize=thread --filter ProcessRunner
make coverage-check
docker compose \
  -f Tests/ComposeCoreTests/Fixtures/process-runner-cancellation/docker-compose.yml \
  config --format json
.build/debug/compose \
  -f Tests/ComposeCoreTests/Fixtures/process-runner-cancellation/docker-compose.yml \
  config --format json
```

Results on the designated Apple silicon MacBook Pro:

- all 37 focused tests pass normally;
- all 37 focused tests pass under ThreadSanitizer with no reported race;
- all 1,249 Swift tests pass in 41 suites at 92.80% line coverage;
- Go statement coverage remains 89.88%;
- Docker Compose V2 v5.3.1 and the source-built Compose command preserve the
  same project, service, image, command, and default-network semantics;
- SwiftFormat, strict SwiftLint, Markdownlint, and `git diff --check` pass.

## Publication evidence

- Pull request
  [`stephenlclarke/container-compose#159`](https://github.com/stephenlclarke/container-compose/pull/159)
  merged as
  [`617c2036f14c34ece761536cddc3d0311a45da2b`](https://github.com/stephenlclarke/container-compose/commit/617c2036f14c34ece761536cddc3d0311a45da2b),
  preserving signed implementation
  `7939874a8fd0dc29097a871c92f319a8f25de402` and signed documentation
  `f1b2c67689682700dd346b4e83d65a69d95016c0`.
- Exact-head
  [CI](https://github.com/stephenlclarke/container-compose/actions/runs/30226922151),
  [CodeQL](https://github.com/stephenlclarke/container-compose/actions/runs/30226922235),
  [Quality](https://github.com/stephenlclarke/container-compose/actions/runs/30226922146),
  and
  [Documentation](https://github.com/stephenlclarke/container-compose/actions/runs/30226922181)
  passed, including ASan.
- The connector reviewed exact head
  `f1b2c67689682700dd346b4e83d65a69d95016c0`, reported no major issues,
  and the final thread-aware audit found zero review threads.
- Exact-main
  [CI](https://github.com/stephenlclarke/container-compose/actions/runs/30228021928),
  [CodeQL](https://github.com/stephenlclarke/container-compose/actions/runs/30228021958),
  and
  [Quality](https://github.com/stephenlclarke/container-compose/actions/runs/30228021947),
  plus
  [Documentation](https://github.com/stephenlclarke/container-compose/actions/runs/30228021922)
  passed. SonarCloud analysis
  `fe1e52b4-9674-4da6-90f8-ce4b0155909d` is for exact revision
  `617c2036f14c34ece761536cddc3d0311a45da2b`; its gate is `OK` with
  82.9% overall coverage, 82.8% new-code coverage, all ratings A, and zero
  unresolved bugs, vulnerabilities, code smells, issues, or hotspots.

## Compatibility and risk

- Observer invocation remains immediately after a successful child start.
- The injected test hook still receives the same cancellation closure.
- Production continues without invoking the test-only cancellation path.
- The process ownership and terminal job-control state are unchanged.

## Checklist

- [x] Signed Conventional implementation commit
- [x] Signed Conventional documentation commit
- [x] Normal focused suite
- [x] Complete Swift and Go coverage gate
- [x] Docker Compose V2 semantic parity
- [x] ThreadSanitizer focused suite
- [x] Pull-request checks and connector review
- [x] Exact-main SonarCloud gate with zero unresolved issues
