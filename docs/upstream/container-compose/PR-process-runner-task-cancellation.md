# Pull request: terminate child processes when Compose tasks are cancelled

## Summary

- Give every asynchronous `ProcessRunner` mode one cancellation-aware process
  group ownership state.
- Reject pre-cancelled launches, send `SIGTERM` after launch, and use bounded
  `SIGKILL` escalation for uncooperative children.
- Latch group termination atomically with cancellation or post-launch failure,
  before any exit or final-pipe callback can clear ownership.
- Resume exactly once after complete group termination, leader reaping, and
  captured-pipe drainage.
- Transfer terminal foreground ownership only when Compose already owns it,
  preserving shell job control for backgrounded invocations.
- Retain Compose's job-control process group independently for inherited
  terminals so stops also relay when Compose itself was launched in the
  background.
- Observe stopped children with `WUNTRACED`, hand the terminal back, and relay
  the stop signal through Compose's complete shell job.
- On resume, restore the child foreground group only for `fg`, then send
  `SIGCONT`; `bg` cannot steal the shell's terminal.
- Restore the retained parent job-control group on exit only while the child
  still owns the terminal, including after an initially backgrounded job
  resumes with `fg`.
- Block `SIGTTOU` while restoring terminal foreground ownership, restore the
  calling thread's signal mask, and propagate restoration failures.
- Convert closed child stdin into `EPIPE` on Darwin so a helper cannot
  terminate the complete Compose process with `SIGPIPE`.
- Cover all I/O modes, explicit stdin, repeated cancellation, leader and
  descendant existence, stdin failure, and a real Compose normalizer call with
  a Docker Compose YAML fixture.

## Intended review delta

Apply signed commit
[`044d836d1faae9e58e577afe0e4860d9decca95c`](https://github.com/stephenlclarke/container-compose/commit/044d836d1faae9e58e577afe0e4860d9decca95c),
`fix(process): terminate children on task cancellation`.

The implementation changes the package manifest, two private ComposeCore files,
one focused test file, and one integration fixture. It changes no public API,
Apple runtime fork, Windows path, or Docker-shaped runtime primitive. See the
companion [issue handoff](ISSUE-process-runner-task-cancellation.md).

## Code map

- `ProcessRunState.prepareForLaunch` atomically installs the continuation and
  prevents launch when cancellation already won.
- `ProcessRunState.didLaunch` closes the launch/cancel race.
- `prepareProcessCommand` uses Apple `ContainerizationOS.Command` to create
  one isolated process group and transfers terminal foreground ownership only
  when Compose's process group is the current terminal owner.
- `processForegroundConfiguration` retains Compose's job-control process group
  independently when an inherited terminal is present, including when the
  shell launched Compose in the background. The same retained group is the
  restoration target if a later `fg` handoff gives the terminal to the child.
- `ProcessRunState.cancel` records `CancellationError` and latches termination
  under the same lock before testing whether completion is possible.
- `ProcessRunState.beginTerminationLocked` prevents exit and final-pipe
  callbacks from clearing group ownership during cancellation.
- `ProcessRunState.startTermination` signals the complete exact-owned group
  once and schedules a 250 ms KILL escalation after that latch.
- `ProcessRunState.completedResultLocked` is the sole continuation owner after
  process exit and required pipe drainage.
- `ProcessRunState.waitForExit` observes stopped children with `WUNTRACED`.
- `ProcessRunState.relayStop` returns terminal ownership, suspends Compose's
  complete process group, and resumes the child group with foreground
  ownership only when the shell selected `fg`.
- `suppressBrokenPipeSignal` uses Darwin's per-descriptor
  `F_SETNOSIGPIPE` behavior before writing explicit stdin.
- `restoreTerminalForegroundProcessGroup` blocks `SIGTTOU`, performs the
  terminal handoff, restores the prior signal mask on every attempted handoff,
  and preserves the first syscall error.
- `terminalForegroundProcessGroupToRestore` permits exit-time restoration only
  while the exiting child process group still owns the terminal.
- `ProcessRunnerTests` publishes real leader and descendant PIDs and verifies
  their shared isolated group, bounded cancellation, and `ESRCH` in every
  asynchronous mode.
- The serialized `ProcessRunnerTests` extensions reproduce closed child stdin,
  verify the resulting write error still terminates and reaps the child, and
  exercise the real normalizer boundary with `docker-compose.yml`.

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

- focused process runner, failure ownership, and Compose integration: 37 tests
  in one serialized suite, all green in normal and ThreadSanitizer runs;
- TERM-ignoring process-tree cancellation completes in about 0.37 seconds per
  I/O mode;
- Docker Compose V2 v5.3.1 accepts and normalizes the tracked fixture;
- source-built Compose accepts the same fixture and preserves its project,
  service, image, command, and default-network semantics;
- the full local gate passes 1,249 Swift tests at 92.79% line coverage and
  89.88% Go statement coverage;
- SwiftFormat and strict SwiftLint pass on every changed Swift file.

## Publication evidence

- Pull request
  [`stephenlclarke/container-compose#157`](https://github.com/stephenlclarke/container-compose/pull/157)
  merged as
  [`41d1e542ea3cbd83b27fb3ae0aab0a5bd857d706`](https://github.com/stephenlclarke/container-compose/commit/41d1e542ea3cbd83b27fb3ae0aab0a5bd857d706),
  preserving the signed implementation and handoff commits.
- Exact-head
  [CI](https://github.com/stephenlclarke/container-compose/actions/runs/30225185496),
  [CodeQL](https://github.com/stephenlclarke/container-compose/actions/runs/30225185529),
  [Quality](https://github.com/stephenlclarke/container-compose/actions/runs/30225185588),
  and
  [Documentation](https://github.com/stephenlclarke/container-compose/actions/runs/30225185484)
  passed, including ASan.
- The connector reviewed exact head
  `cee556716519fa98a827f1578031155bdc67adb8`, reported no major issues,
  and left zero unresolved review threads after every earlier finding received
  a direct author response.
- The first exact-main
  [CI](https://github.com/stephenlclarke/container-compose/actions/runs/30225979068),
  [CodeQL](https://github.com/stephenlclarke/container-compose/actions/runs/30225979078),
  [Quality](https://github.com/stephenlclarke/container-compose/actions/runs/30225979070),
  and
  [Documentation](https://github.com/stephenlclarke/container-compose/actions/runs/30225979071)
  passed for merge `41d1e542...`. SonarCloud analysis
  `f1987b60-7da4-4ee8-941f-2094d4019eaf` accepted that exact revision with
  gate `OK`, 82.9% overall coverage, 82.7% new-code coverage, and zero bugs,
  vulnerabilities, or hotspots. Its three new maintainability findings are
  corrected by the linked
  [process-start observer follow-up](PR-process-start-observer-maintainability.md)
  before prerelease publication.

## Compatibility and risk

- Successful commands preserve their existing exit status and captured text.
- Launch failures remain immediate and do not schedule termination.
- Cancellation waits for EOF so captured readers cannot outlive their child.
- Descendants share the exact-owned process group and cannot retain a captured
  pipe after their leader exits.
- Concurrent leader-exit and final-pipe callbacks cannot complete cancellation
  before group termination has been latched.
- Closed stdin raises a write error rather than delivering process-wide
  `SIGPIPE` on Darwin.
- SIGKILL is sent only to the exact still-owned process group after the grace
  period.
- Inherited terminal modes restore the foreground process group after reaping
  without allowing `SIGTTOU` to suspend Compose.
- Backgrounded Compose invocations never transfer the shell's foreground
  terminal to a child helper, but retain their own job-control group so a
  stopped inherited-terminal helper suspends the complete shell job.
- Foreground child stop signals suspend the complete Compose shell job instead
  of leaving the parent blocked in `waitpid`.
- `fg` restores the isolated child foreground group before `SIGCONT`; `bg`
  continues without changing shell terminal ownership.
- Process exit restores Compose's retained parent job-control group only while
  the child still owns the terminal. A `bg`-resumed child therefore cannot
  steal ownership from the shell, while an `fg`-resumed background launch
  returns ownership to Compose.
- The private state is scoped to one invocation and introduces no shared
  process registry or global signal handler.

## Checklist

- [x] Signed Conventional implementation commit
- [x] Compose-layer-only production change
- [x] All asynchronous I/O modes and explicit stdin covered
- [x] Pre-launch, repeated, and TERM-ignoring cancellation covered
- [x] Docker Compose YAML integration fixture
- [x] Docker Compose V2 and source-built normalization confirmation
- [x] Complete Swift and Go coverage gate
- [x] Signed Conventional documentation commit
- [ ] Pull-request checks and connector review
- [ ] Exact-main CI, CodeQL, and SonarCloud gate
- [ ] Slice prerelease, checksums, attestations, and Homebrew update
