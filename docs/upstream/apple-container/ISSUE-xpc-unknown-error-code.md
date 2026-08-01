# Unknown XPC Error Codes Can Terminate The Client

## Problem

`XPCMessage.error()` decodes the error code supplied by its XPC peer and passes
that string to `ContainerizationError.init(_:message:cause:)`. In the pinned
`containerization` 0.40.1 implementation, the raw-string initializer calls
`fatalError` when the value is not one of the currently known error codes.

A malformed peer or a newer same-user daemon can therefore terminate an older
client merely by returning a syntactically valid error payload containing a
new code. This is a generic stock `apple/container` defect; it is not specific
to Docker Compose or the supported fork.

## Reproduction Boundary

- Stock base: `apple/container:main` at
  `6e65319fe476ffe8db8ddaf828a537ed36fe2859`.
- Affected source: `Sources/ContainerXPC/XPCMessage.swift`.
- Trigger payload:
  `{"code":"newerPeerCode","message":"from a newer peer"}`.
- Existing behavior: `ContainerizationError.Code.init(rawValue:)` traps.
- Required behavior: reject the payload as a sanitized typed error without
  terminating the process.

## Expected Behavior

- Preserve every error code understood by the pinned client and its message.
- Treat malformed JSON and unknown codes as a malformed peer payload.
- Return `.internalError` with the existing sanitized malformed-payload
  message; do not reflect untrusted peer content.
- Keep the XPC wire schema and all known-code behavior unchanged.

## Apple-Shaped Candidate

- Local branch: `upstream/fix-xpc-unknown-error-code`.
- Signed commit:
  `ec60a81d3d47a76e8a356c2bc3e457807c38d10c`.
- The commit is based directly on the stock Apple head above and contains only
  the decoder guard, an isolated `ContainerXPCTests` target, and regressions.
- No Apple issue, branch, comment, or pull request has been created or changed.

## Overlap Review

A read-only GitHub search on 1 August 2026 found no open `apple/container`
issue or pull request directly addressing peer error-code decoding. Open
[apple/container#1862](https://github.com/apple/container/pull/1862) handles
unknown routes and request cancellation, not validation of the error code in
a received payload. Pull request #1935 is stacked on that cancellation work
and likewise has no decoder overlap. Re-run this search at the deferred
publication gate.

## Acceptance Evidence

- An unknown literal wire code returns sanitized `.internalError` without a
  trap.
- Parameterized coverage round-trips all 11 codes understood by
  `containerization` 0.40.1 and preserves their messages.
- Focused warnings-as-errors testing passes in normal and Thread Sanitizer
  builds with no sanitizer report.
- Repository Swift formatting, licence-header validation, and diff checks
  pass.
- An independent review found no release-blocking correctness issue and
  confirmed the defect exists unchanged on stock Apple `main`.

## Residual Constraint

The allowlist intentionally fails closed. If `ContainerizationError.Code`
gains a case, an older client will safely report malformed `.internalError`
instead of preserving the newer semantic code. A future
`apple/containerization` API could expose a failable public code parser and
remove the duplicated list; that API improvement is not required to close the
client crash.

## Publication Gate

Keep the candidate local until every planned Container-family development
wave and integrated compatibility, fault, security, migration, performance,
documentation, and repository-hygiene gate is complete. Any Apple publication
then requires explicit owner authorization and a fresh overlap review.
