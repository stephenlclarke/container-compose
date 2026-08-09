# Pull Request: Finish the Build Request Stream on Terminal Completion

## Summary

- Recognize the existing terminal build completion packet in the host receive
  loop.
- Finish the host request half after the loop completes.
- Add narrow regressions for terminal and nonterminal packets.
- Preserve the existing protocol, cancellation, and failure semantics.

See the companion [issue handoff](ISSUE-build-stream-completion.md).

## Intended Review Delta

Apply signed commit `a661e67c8e7713483eb448493c7b4a35f346d9b3` from local
branch `upstream/net-ipv6-only-runtime-integration-02` after a fresh rebase on
current `apple/container:main`. The proposed delta is limited to
`Sources/ContainerBuild/BuildPipelineHandler.swift` and
`Tests/ContainerBuildTests/BuildPipelineCompletionTests.swift`.

The receive loop maps `CommandComplete` to the existing `buildComplete`
lifecycle error. A `defer` finishes the request sender as the loop exits. This
allows a well-behaved peer to observe EOF and finish its response without a
timeout or out-of-band close.

## Validation

On this MacBook Pro, at the exact signed revision:

```console
swift test --filter BuildPipelineCompletionTests
swift test --enable-code-coverage --filter BuildPipelineCompletionTests
```

Both focused tests pass. Coverage shows two executions of the helper, with the
return and throw paths each exercised once. The source-matched real runtime
certificate subsequently completes a BuildKit-backed Compose lifecycle, which
is behavioral proof of the live build boundary rather than a synthetic mock.

## Compatibility and Risk

- No protocol field, wire message, or public API changes.
- Nonterminal packets retain their current behavior.
- A terminal completion now ends the client request half deterministically.
- The change relies on the peer preserving the existing terminal completion
  packet; the companion builder-shim handoff provides that behavior.

## Checklist

- [x] Narrow generic source/test candidate on an `upstream/` branch
- [x] Signed commit and focused regression coverage
- [x] Source-matched behavioral certificate on the local stack
- [x] Local issue and pull-request handoffs registered centrally
- [ ] Fresh stock-Apple rebase and overlap review
- [ ] Stock focused and repository validation
- [ ] Programme-wide publication gate and explicit authorization
