# Reattach standard streams to a running container

## Summary

`container compose attach SERVICE` needs an Apple runtime primitive that can
reattach a client to the original process's standard input, output, error, and
PTY after the container is already running. The current output-only Compose
path is intentionally implemented as `logs --follow`; it is not an
interactive attach substitute.

This is tracked upstream by [apple/container#378](https://github.com/apple/container/issues/378).

## Why This Cannot Be Implemented in `container-compose`

The runtime accepts the original standard-file-descriptor handles only while it
bootstraps the sandbox. Its process routes create, start, exec, resize, signal,
and wait processes, but provide no route that returns or multiplexes a running
main process's streams. Once started, the main process writes through the
runtime's log writer; replaying that persisted output cannot provide stdin,
terminal semantics, resize handling, signal delivery, or a detach-key escape
sequence.

The current `container start --attach` implementation makes the same boundary
explicit: it rejects attachment to an already-running container. A Compose-side
client cannot safely recreate the original process or infer which PTY bytes
belong to a new client without changing runtime ownership of those streams.

## Required Runtime Shape

- An attach-session API for a running container's original init process.
- Bidirectional stdin/stdout/stderr forwarding with a defined multi-client
  policy and disconnect cleanup.
- PTY resize and signal-proxy support for terminal-backed processes.
- A lifecycle-safe detach operation so Compose can own Docker-compatible
  detach-key handling without killing the container.
- Focused runtime integration coverage for reconnect, stream closure, and a
  container that continues running after the client detaches.

## Compose Disposition

- Supported now: `container compose attach --no-stdin SERVICE` follows output
  through the log API; `--detach-keys` is accepted as a no-op in that mode.
- Intentionally partial: default interactive attach, detach-key handling, and
  full stream/signal reattachment.
- Do not emulate interactive attach with `exec`, `tmux`, or log replay. Those
  create a different process or lose terminal semantics and would misrepresent
  Docker Compose behavior.
