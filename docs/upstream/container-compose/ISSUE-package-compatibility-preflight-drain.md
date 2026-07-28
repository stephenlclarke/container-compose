# Package compatibility preflight can deadlock on full output pipes

## Problem

The runtime package-compatibility preflight attached separate stdout and stderr
pipes to `container system version` and `container system status`, waited for
the child to exit, and only then drained either pipe.

A child that wrote more than the host pipe capacity could block while writing.
The parent simultaneously waited for that child to exit, so every
runtime-backed Compose command could hang before orchestration started. The
same direct `Foundation.Process` path also sat outside the cancellation
ownership already established in the shared Compose process runner.

## Resolution

Signed implementation commit
[`81d32eb24493f294ccdc86e7ff0c52881995c94a`](https://github.com/stephenlclarke/container-compose/commit/81d32eb24493f294ccdc86e7ff0c52881995c94a)
makes the package preflight asynchronous and routes both checks through
`ComposeCore.ProcessRunner`. Signed review follow-up `96ac7830` preserves a
complete UTF-8 scalar at the diagnostic byte boundary and reports the exact
number of bytes omitted. Signed connector-review correction `045d020c`
propagates `CancellationError` from both compatibility awaits rather than
converting cancellation into install or service guidance. Signed
connector-review correction `9db8f060` preserves the original stdout and
stderr bytes through the package boundary so malformed UTF-8 cannot alter the
64 KiB source boundary or omitted-byte count.

The corrected path:

- drains stdout and stderr concurrently while the child runs;
- supplies an empty stdin payload and closes the writer;
- inherits the process runner's task-cancellation and process-group ownership;
- waits for process exit and complete pipe drainage before returning;
- preserves stderr precedence for a failed command;
- falls back to stdout when stderr is empty;
- limits a displayed failure diagnostic at a 64 KiB raw-stream boundary,
  preserves complete valid UTF-8 scalars, and reports the exact omitted source
  byte count; and
- preserves the existing successful JSON and service-readiness behaviour.

## Ownership boundary

| Layer | Responsibility |
| --- | --- |
| Compose plugin | Decide which invocations require package and service preflight checks. |
| `ComposeCore.ProcessRunner` | Own the host child, process group, cancellation, stdin, and concurrent output drainage. |
| Apple runtime forks | Report component versions and service status through the existing CLI. |
| Docker compatibility | Remains in Compose command policy and does not affect this host-process correction. |

No Apple runtime fork or new compatibility primitive is required.

## Source map

- `Sources/ComposePlugin/ContainerPackageCompatibility.swift` makes the
  argument-based preflight asynchronous, calls the shared process runner, and
  bounds failed-command diagnostics.
- `Sources/ComposeCore/ProcessRunner.swift` retains package-private raw stream
  data while preserving the public string result API.
- `Sources/ComposePlugin/ComposePlugin.swift` awaits the preflight before
  dispatching a runtime-backed command.
- `Tests/ComposePluginTests/ContainerPackageCompatibilityTests.swift` exercises
  concurrent large-output drainage, stderr selection, diagnostic truncation,
  cancellation latency, and child reaping.

## Acceptance

- A fake command writes 307,200 bytes to both stdout and stderr and terminates.
- A failed command still selects stderr after first writing 307,200 bytes to
  stdout.
- A 307,200-byte failure diagnostic is limited to 64 KiB and reports 241,664
  omitted bytes.
- A multibyte scalar crossing the 64 KiB boundary is omitted intact without a
  replacement character, and its complete byte count is reported.
- A malformed byte before the boundary renders as a replacement character
  without changing the exact omitted source-byte count.
- Cancelling a TERM-ignoring preflight returns `CancellationError` within two
  seconds.
- Cancellation from either the version or service-status await is propagated.
- The child PID reports `ESRCH` after cancellation completes.
- Existing package mismatch, missing executable, and service readiness
  diagnostics remain covered.
- Repository build, test, format, lint, dependency, and diff gates pass.

## Compatibility and deletion

This is a private implementation change. Runtime command selection, package
matching, user guidance, successful JSON decoding, and service readiness
semantics are unchanged.

The host preflight remains Compose-owned even if all generic Apple runtime work
lands because the plugin invokes the installed `container` executable before
entering the runtime API boundary.
