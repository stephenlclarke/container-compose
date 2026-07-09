# Exec Sessions Can Survive Client Disconnects And Block Later Exec Or Stop

## I Have Done The Following

- [x] I have searched the existing issues
- [x] If possible, I've reproduced or inspected the issue using the `main` branch of this project

## Steps To Reproduce

This handoff tracks the runtime cleanup portion of [apple/container#1916](https://github.com/apple/container/issues/1916) and the overlapping upstream proposal in [apple/container#1926](https://github.com/apple/container/pull/1926).

One affected flow is:

1. Start a long-running container.
2. Start an interactive or SSH-backed `container exec` session.
3. Drop the client connection abruptly, for example by closing the terminal or losing the SSH client before the exec process exits cleanly.
4. Attempt another `container exec` or stop the container.

## Problem Description

The server already creates one `XPCServerSession` per client connection and network attachment allocation uses `session.onDisconnect` for cleanup. The container process creation route still wrapped `ContainersHarness.createProcess` through the session-unaware `XPCServer.route` adapter, so the harness could not attach exec-process cleanup to the client connection that created the process.

That leaves a path where an ad hoc exec process can outlive the dropped client. Later exec, stop, and Compose lifecycle operations can then appear hung or inconsistent because stale process state remains in the runtime.

The Stephen fork-backed fix keeps the Apple-shaped boundary small:

- route `containerCreateProcess` to a session-aware harness method;
- register a disconnect handler only after the runtime successfully creates an attached process;
- send `SIGKILL` to that specific attached process ID if the client connection closes unexpectedly;
- preserve detached exec process lifetime after the CLI exits;
- log cleanup failures at debug level because the process may already have exited normally.

The broader stop-timeout half of [apple/container#1926](https://github.com/apple/container/pull/1926) was reviewed but not copied into the fork in this slice because it starts a parallel force-kill cleanup path that can race normal graceful-stop cleanup. A separate stop-timeout design should preserve single-owner cleanup semantics.

## Environment

- OS: macOS 26 class hosts, matching the upstream issue report
- Container: Stephen fork-backed `container` main after `1658fbe`
- Related runtime consumer: `container-compose` exec, lifecycle hook, stop, down, and attached `up` paths

## Code Of Conduct

- [x] I agree to follow this project's Code of Conduct
