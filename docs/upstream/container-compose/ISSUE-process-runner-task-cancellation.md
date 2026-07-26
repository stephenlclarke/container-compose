# Cancelled Compose tasks must terminate their child processes

## Problem

`ProcessRunner` used checked continuations for its three asynchronous
Foundation `Process` modes, but none of those continuations had a task
cancellation handler. Cancelling a build, pull, push, normalizer, publish, or
runtime-helper operation therefore left its child running until natural exit.
The caller could remain suspended while that child retained pipes, locks, or
other external resources.

The affected modes were:

- captured stdout and stderr, with optional explicit stdin;
- captured stdout with inherited stdin and stderr for prompts;
- fully inherited terminal I/O.

Replacing the current process is intentionally outside this scope because a
successful `exec` has no parent Swift task left to own.

## Resolution

Signed commit
[`044d836d1faae9e58e577afe0e4860d9decca95c`](https://github.com/stephenlclarke/container-compose/commit/044d836d1faae9e58e577afe0e4860d9decca95c)
introduces one private, locked process-run state shared by every asynchronous
mode.

The state:

- rejects an already-cancelled task before launching a child;
- creates one process group per command through `ContainerizationOS.Command`;
- records cancellation that races the synchronous launch;
- latches termination while still holding the completion-state lock, before an
  exit or final-pipe callback can clear process-group ownership;
- sends `SIGTERM` to the complete owned process group;
- escalates the complete group to `SIGKILL` after a 250 ms grace period;
- waits for group termination, leader reaping, and captured-pipe EOF;
- selects `CancellationError` over a cancellation-induced exit status;
- removes the checked continuation before resuming it;
- hands off a terminal only when Compose's process group already owns its
  foreground, leaving shell-backgrounded invocations in the background;
- retains Compose's job-control process group independently when an inherited
  terminal is present, so a background-launched child stop can still suspend
  the complete shell job;
- observes stopped foreground children, returns terminal ownership, and relays
  the stop signal to Compose's complete shell job;
- restores the child foreground group and sends `SIGCONT` after `fg`, while a
  `bg` resume continues the child without stealing the terminal;
- restores the retained parent job-control process group after inherited I/O
  only while the exiting child still owns the terminal, including after an
  initially backgrounded job resumes with `fg`;
- blocks `SIGTTOU` during that restoration, restores the calling thread's
  original signal mask on every attempted handoff, and reports syscall
  failures through the process result;
- configures Darwin child-stdin pipes to return `EPIPE` instead of terminating
  the Compose process with `SIGPIPE`.

This makes launch, stream drainage, termination, and completion one ownership
unit without changing the public `CommandRunning` API.

## Apple-shaped boundary

| Layer | Responsibility |
| --- | --- |
| `ComposeCore` | Own host helper processes launched for Compose operations. |
| `ContainerizationOS.Command` | Create the isolated host process group. |
| Apple runtime forks | Own runtime and guest processes behind their native APIs. |
| Docker compatibility | Remains in Compose commands and the compose-go normalizer. |

The cancellation fix is macOS- and Linux-host compatible through the existing
Darwin/Glibc signal imports. Per-descriptor `SIGPIPE` suppression uses Darwin's
`F_SETNOSIGPIPE`, so the closed-stdin hardening is intentionally macOS-specific.
The package manifest exposes the existing `ContainerizationOS` product to
`ComposeCore`; no Apple fork source changes are required. The change adds no
Windows branch and requires no change to `apple/container` or
`apple/containerization`.

## Source map

- `Package.swift` exposes the already-pinned `ContainerizationOS` product to
  `ComposeCore`.
- `Sources/ComposeCore/ProcessRunner.swift` launches isolated process groups
  and consolidates the three previous result states into one
  cancellation- and job-control-aware owner.
- `Sources/ComposeCore/ProcessJobControl.swift` isolates terminal ownership,
  background job-control group selection, stop relay, and ownership-checked
  restoration behind narrow internal helpers.
- `Tests/ComposeCoreTests/ProcessRunnerTests.swift` covers pre-launch,
  captured, inherited, prompt-inheriting, explicit-stdin, repeated, and
  TERM-ignoring process-tree cancellation, launched-child stdin failure, and
  terminal foreground restoration selection, ordering, and failure handling.
- `Tests/ComposeCoreTests/Fixtures/process-runner-cancellation/docker-compose.yml`
  supplies the Compose normalizer integration fixture.

## Acceptance

- Every asynchronous I/O mode returns `CancellationError` within two seconds.
- A TERM-ignoring child exercises the bounded SIGKILL escalation.
- A TERM-ignoring descendant in the same process group cannot retain captured
  pipes or survive its leader.
- Repeated cancellation and late termination or pipe callbacks cannot
  double-resume the continuation.
- Cancellation cannot complete between recording its error and latching
  termination, even when child exit and final-pipe callbacks arrive together.
- Closed child stdin returns an ordinary write error and still terminates and
  reaps the launched child.
- Terminal restoration cannot stop Compose with `SIGTTOU`, always attempts to
  restore the prior signal mask after foreground handoff, and preserves the
  first syscall failure.
- A shell-backgrounded Compose invocation cannot transfer the shell's
  foreground terminal to its helper.
- A shell-backgrounded Compose invocation retains its own job-control group so
  an inherited-terminal child stopped by `SIGTTIN` relays the stop through the
  complete shell job.
- Ctrl-Z and other foreground stop signals suspend the complete Compose shell
  job, and `fg` resumes the isolated child group without deadlocking `waitpid`.
- A `bg` resume cannot transfer the shell-owned terminal to the child.
- Process exit restores the retained parent job-control group only if the
  exiting child process group still owns the terminal, including after an
  initially backgrounded job resumes with `fg`.
- Each launched child PID reports `ESRCH` after the task returns.
- The tracked YAML fixture is accepted by Docker Compose V2 and the
  source-built Compose normalizer path.
- Complete Swift and Go coverage floors remain green.

## Compatibility and deletion

Normal process results, uncaught-signal status, output decoding, launch errors,
inherited terminal behavior, and the public command-running contract are
unchanged. Foreground stop and continue now preserve normal shell job control,
and cancellation has the resource ownership callers already expect from
structured concurrency.

This Compose-owned process boundary remains necessary even if every native
Apple runtime proposal lands because the compose-go normalizer and other host
helpers are launched directly by Compose.
