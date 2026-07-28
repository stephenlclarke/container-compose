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
64 KiB source boundary or omitted-byte count. Signed connector-review
correction `e0ad1dfe` replaces the proportional per-byte diagnostic model with
a single pass over the raw data that retains only the bounded rendered prefix
and byte offsets. Signed connector-review correction `4bf2eac6` preserves the
existing public `CommandResult` equality contract despite its new
package-private raw stream storage. Signed test correction `592266a7` measures
the full packaged CLI preflight in an isolated process and enforces a maximum
resident-memory ceiling. Signed connector-review correction `3ed87228` routes
host termination signals through the existing Compose signal proxy, cancels
and reaps the isolated preflight group, and retains the signal until the
executable returns its conventional shell status. Signed connector-review
correction `fbe0ce05` installs that proxy before creating the child task and
adds a package-private process-runner mode that drains each stream while
retaining only a bounded prefix and the exact omitted-byte count. Signed final
correction `b65d18a6` represents an all-whitespace retained prefix as truncated
when omitted bytes remain, preserving stderr priority without claiming the
unretained content. Signed connector-review correction `62a40d48` applies the
64 KiB display limit from the absolute raw-stream start, so trimming leading
whitespace cannot shift the UTF-8 lookahead boundary or split a valid scalar.
Signed manual-review correction `b07e9da8` reports the exact non-whitespace
source-byte count when leading whitespace consumes the complete display budget,
rather than returning an empty diagnostic.

The corrected path:

- drains stdout and stderr concurrently while the child runs;
- retains at most 64 KiB plus UTF-8 boundary lookahead from each preflight
  stream while recording the exact number of omitted bytes;
- supplies an empty stdin payload and closes the writer;
- inherits the process runner's task-cancellation and process-group ownership;
- installs host-signal handling before creating the child task, then converts a
  signal into task cancellation before the executable returns the corresponding
  shell status;
- waits for process exit and complete pipe drainage before returning;
- preserves stderr precedence for a failed command;
- preserves that stderr precedence when its retained prefix contains only
  whitespace but its exact omitted-byte count proves more stderr exists;
- falls back to stdout when stderr is empty;
- limits a displayed failure diagnostic at a 64 KiB absolute raw-stream
  boundary, preserves complete valid UTF-8 scalars, and reports the exact omitted
  source byte count; and
- preserves the existing bounded successful JSON and service-readiness
  behaviour.

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
  bounds failed-command diagnostics with an incremental raw-byte scan.
- `Sources/ComposeCore/ProcessRunner.swift` retains package-private raw stream
  prefixes and omitted-byte counts while preserving the unbounded public string
  result API.
- `Sources/ComposePlugin/ComposePlugin.swift` awaits the preflight before
  dispatching a runtime-backed command.
- `Tests/ComposePluginTests/ContainerPackageCompatibilityTests.swift` exercises
  concurrent large-output drainage, stderr selection, diagnostic truncation,
  cancellation latency, child reaping, and proxy-before-launch ordering.
- `Tests/ComposeCoreTests/ProcessRunnerBoundedOutputTests.swift` proves bounded
  capture drains MiB-sized streams and reports exact omitted-byte counts.

## Acceptance

- Fake commands write 65,537 and 307,200 bytes to both stdout and stderr,
  drain fully, and reject oversized successful stdout with its exact byte count.
- A bounded process-runner capture drains 1 MiB of stdout and 2 MiB of stderr
  while retaining exactly 1 KiB of each and reporting exact omitted counts.
- A failed command still selects stderr after first writing 307,200 bytes to
  stdout.
- A 307,200-byte failure diagnostic is limited to 64 KiB and reports 241,664
  omitted bytes.
- A multibyte scalar crossing the 64 KiB boundary is omitted intact without a
  replacement character, and its complete byte count is reported.
- A malformed byte before the boundary renders as a replacement character
  without changing the exact omitted source-byte count.
- Publicly identical `CommandResult` values remain equal when their retained raw
  bytes differ.
- A failing packaged CLI can emit 16 MiB to stderr, render fewer than 67,000
  diagnostic bytes, and remain below 320 MiB maximum resident memory.
- The 16 MiB isolated memory regression passes with Address Sanitizer.
- Cancelling a TERM-ignoring preflight returns `CancellationError` within two
  seconds.
- Cancellation from either the version or service-status await is propagated.
- The child PID reports `ESRCH` after cancellation completes.
- Sending SIGINT to the full CLI reaps a TERM-ignoring preflight child and exits
  with status 130.
- A delayed signal proxy observes that the preflight child cannot start before
  proxy installation completes.
- A failed child that writes stdout plus 65,539 retained whitespace bytes and
  omitted stderr reports `[truncated 65552 bytes]` from stderr rather than
  falling back to stdout.
- Four leading whitespace bytes followed by a four-byte UTF-8 scalar crossing
  the retained prefix cannot shift the display budget, emit replacement
  characters, or render more than 64 KiB of source bytes.
- A one-byte failure following 64 KiB of leading whitespace reports
  `[truncated 1 byte]` rather than disappearing.
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
