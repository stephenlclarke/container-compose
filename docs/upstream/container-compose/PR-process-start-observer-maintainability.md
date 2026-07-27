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

Hosted review, exact-main SonarCloud, and final publication evidence are added
before this follow-up closes.

## Compatibility and risk

- Observer invocation remains immediately after a successful child start.
- The injected test hook still receives the same cancellation closure.
- Production continues without invoking the test-only cancellation path.
- The process ownership and terminal job-control state are unchanged.

## Checklist

- [x] Signed Conventional implementation commit
- [ ] Signed Conventional documentation commit
- [x] Normal focused suite
- [x] Complete Swift and Go coverage gate
- [x] Docker Compose V2 semantic parity
- [x] ThreadSanitizer focused suite
- [ ] Pull-request checks and connector review
- [ ] Exact-main SonarCloud gate with zero unresolved issues
