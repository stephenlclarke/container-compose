# Pull Request: Reject Unknown XPC Peer Error Codes

## Summary

- Decode only error codes understood by the client.
- Convert unknown or malformed peer payloads to the existing sanitized
  `.internalError` response instead of invoking a trapping raw-code parser.
- Preserve the wire representation and every currently supported code and
  message.
- Add stock-compatible tests for the unknown-code regression and all 11 known
  codes.

See the companion
[issue handoff](ISSUE-xpc-unknown-error-code.md).

## Intended Review Delta

Apply the signed commit
`ec60a81d3d47a76e8a356c2bc3e457807c38d10c` from local branch
`upstream/fix-xpc-unknown-error-code` to `apple/container:main` at
`6e65319fe476ffe8db8ddaf828a537ed36fe2859`.

The commit changes only:

- `Sources/ContainerXPC/XPCMessage.swift`;
- the package declaration for `ContainerXPCTests`; and
- `Tests/ContainerXPCTests/XPCMessageTests.swift`.

## Motivation

The XPC error payload is peer-controlled and can legitimately cross a version
boundary. `ContainerizationError(String, ...)` is not a validating API: its
pinned implementation traps for an unknown string. A daemon returning a code
introduced after the client was built can therefore terminate that client.

The proposed decoder maps the finite set supported by the pinned client to
typed values before construction. Unknown values use the same sanitized error
already returned for malformed JSON. No Docker-specific policy belongs in
this patch.

A read-only overlap search on 1 August 2026 found no direct open Apple issue or
pull request. `apple/container#1862` is adjacent cancellation and unknown-route
work but does not validate a peer-supplied error code, so the candidate neither
duplicates nor depends on it.

## Validation

The following gates passed on this MacBook Pro in a dedicated stock-Apple
worktree:

```console
swift test -Xswiftc -warnings-as-errors --filter XPCMessageTests
swift test --sanitize=thread -Xswiftc -warnings-as-errors \
  --filter XPCMessageTests
make swift-fmt-check
make check-licenses
git diff --check
```

Results:

- the unknown literal peer code regression passes;
- all 11 supported code cases preserve code and message;
- Thread Sanitizer reports no race;
- strict repository formatting and licence checks pass; and
- the commit has a valid ED25519 signature.

## Compatibility And Risk

- The XPC JSON schema is unchanged.
- Known peers observe no behavior change.
- Unknown codes now fail closed as `.internalError` instead of terminating the
  process.
- The allowlist must be extended when the pinned error library adds a code.
  Until then, version skew remains safe but loses the newer semantic code.
- The new test target directly depends on the `Containerization` product to
  import its public error type; this is explicit but makes the focused test
  build comparatively heavyweight.

## Checklist

- [x] Narrow stock-Apple commit based on current fetched `main`
- [x] Signed Conventional Commit on an `upstream/` branch
- [x] Unknown-code and complete known-code regression coverage
- [x] Warnings-as-errors normal and Thread Sanitizer validation
- [x] Formatting, licence, and diff gates
- [x] Independent correctness and upstream-applicability review
- [x] Matching issue and pull-request handoffs
- [ ] Fresh Apple overlap search at programme-wide publication time
- [ ] Full current stock test suite before submission
- [ ] Explicit authorization to publish to Apple
