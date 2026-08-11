# Pull Request: Complete Successful Bidirectional Build Streams

## Summary

- Send the generated terminal `CommandComplete` packet after BuildKit returns.
- Wait for client request EOF before completing the server response.
- Serialize outbound packets through a cancellation-aware helper.
- Remove the incorrect duplicate close of the client-owned status channel.

See the companion [issue handoff](ISSUE-build-stream-completion.md).

## Intended Review Delta

After a fresh rebase on `apple/container-builder-shim:main`, apply the signed
local series from `upstream/build-progress-completion`:

1. `89778a9f1938331c9b7cb0094831358e2b730d71` — remove the duplicate final
   progress/status close.
2. `418e3c50f1ae664da3637ad81df8fc70ce630fd9` — send terminal completion and
   coordinate the bidirectional stream shutdown.

The change is confined to the generic server/pipeline lifecycle and its narrow
tests. It contains no Compose, Docker, provider, or local-runtime policy.

## Validation

On this MacBook Pro, at the exact signed series:

```console
go test ./pkg/stream ./pkg/server -count=1 -coverprofile=completion.coverprofile
go vet ./pkg/stream ./pkg/server
git diff --check
```

All commands pass. The new `Send` and `buildCompletePacket` helpers are 100%
covered. The real BuildKit `PerformBuild` path is deliberately not replaced by
a mock; a source-matched runtime certificate exercises it through the public
CLI and completes the dependent IPv6-only Compose lifecycle.

## Compatibility and Risk

- The existing generated terminal packet and wire schema are reused.
- The change sends no terminal packet on BuildKit failure.
- Cancellation remains allowed while the peer waits for request EOF.
- The host-side companion change is required for the full duplex completion
  property; either repository can retain backward-compatible behavior alone.

## Checklist

- [x] Narrow generic source/test candidate on an `upstream/` branch
- [x] Signed two-commit series with focused test, vet, and diff gates
- [x] Exact local behavioral certificate
- [x] Local issue and pull-request handoffs registered centrally
- [ ] Fresh stock-Apple rebase and overlap review
- [ ] Stock focused and repository validation
- [ ] Programme-wide publication gate and explicit authorization
