# Bug: process signals use the wrong XPC value type

## Bug Details

`ClientProcess.kill(_:)` writes the `.signal` XPC value as an integer, while the API server reads that key as a string and resolves it through the Linux signal table. The server therefore treats every signal sent through this client path as missing.

The mismatch affects public `ContainerAPIClient` callers and the foreground `container attach` signal proxy used by interactive Compose workflows.

## Reproduction

1. Start a Linux container whose init process traps `SIGINT` and exits with a distinctive status.
2. Attach through the `container` client path with signal proxying enabled.
3. Send `SIGINT` to the attached client.
4. Before the correction, the server rejects the request as `invalidArgument: "missing signal in xpc message"` and the workload remains running.

Raw Darwin signal numbers are not a valid fallback for this contract. For example, `SIGUSR1` is signal 30 on macOS but signal 10 on Linux.

## Expected Behavior

The client sends the canonical signal name that the API server can resolve against the Linux signal table. Common and platform-divergent signals reach the requested Linux process, while unnamed real-time signals retain a numeric-string fallback.

## Ownership and Compatibility

This is a generic macOS client/runtime protocol correction in `apple/container`. Compose owns no XPC workaround and continues to invoke the normal attach and lifecycle APIs. The correction adds no Windows path and changes no public Swift API.

## Existing Upstream Work

- Bug: [apple/container#1941](https://github.com/apple/container/issues/1941)
- Related reports: [apple/container#1876](https://github.com/apple/container/issues/1876) and [apple/container#1747](https://github.com/apple/container/issues/1747)
- Preferred fix: [apple/container#1997](https://github.com/apple/container/pull/1997)

The fork port preserves Chris Cheng's authorship and has stable patch ID `aae90dc092ef523577bc936fbd82d075d8c8885d`, identical to the upstream pull request.

## Validation Expectations

- Unit tests cover common signal names, a signal whose Darwin and Linux numbers differ, and the numeric-string fallback.
- A live macOS attach session forwards `SIGINT` to a Linux PID 1 that exits with status 42.
- The same committed Compose fixture passes against Docker Compose V2 and the matched Apple runtime.
