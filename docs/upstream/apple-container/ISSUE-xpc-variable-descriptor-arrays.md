# Bug: log-follow replies with one XPC descriptor trap the macOS client

## Summary

The generic `XPCMessage.fileHandles(key:)` decoder assumed every XPC array
contained exactly two file descriptors. `container logs --follow` returns one
descriptor, so decoding index `1` from that one-element array invoked the
macOS XPC API out of bounds and terminated the client with `SIGTRAP`.

## Reproduction on macOS

1. Start a Container runtime and create a container whose process exits
   immediately, including one configured with an empty entrypoint override.
2. Request its live log stream through `container logs --follow`, or run the
   Docker Compose v2 empty-process-override parity fixture.
3. Before the correction, the follow-log reply contains one descriptor and
   the client raises an XPC API-misuse trap while attempting to duplicate a
   second descriptor.

## Expected behavior

The shared decoder must duplicate precisely the descriptors that are present
in the XPC array. One-descriptor follow-log replies and two-descriptor regular
log replies must both remain valid; missing or non-array values must fail
without an XPC API misuse.

## Ownership and boundary

`ContainerXPC.XPCMessage` is the neutral descriptor-decoding boundary used by
runtime clients. The correction belongs there, not in Compose and not in the
log-follow caller. It does not alter guest logging or introduce Docker-shaped
behavior.

## Commit tracking

- `a8f6cae4fc49f10dcfeb3241247ce82cef9c7749` —
  `fix(xpc): preserve variable descriptor arrays`.

## Validation expectations

- Unit coverage exercises empty, one-, and two-descriptor arrays and rejects
  non-array values.
- The complete Container coverage suite validates the source distribution.
- The source-matched Docker Compose v2 empty-process-override fixture verifies
  the previously crashing follow-log path.
