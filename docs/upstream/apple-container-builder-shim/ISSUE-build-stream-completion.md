# Successful Builds Need a Terminal Bidirectional Stream Completion

## Problem

When BuildKit returns successfully, the builder shim can finish the build work
while its bidirectional RPC remains unresolved. The host needs an explicit
terminal `CommandComplete` packet to distinguish successful work completion
from ordinary progress, then the peer needs request EOF before it can close its
response. Closing the client-owned status channel directly is incorrect and
can panic under the vendored client lifecycle.

This is a generic stream ownership and completion problem, not a Compose or
Docker compatibility feature.

## Reproduction Boundary

- Candidate branch: `upstream/build-progress-completion`.
- Signed commits:
  `89778a9f1938331c9b7cb0094831358e2b730d71` and
  `418e3c50f1ae664da3637ad81df8fc70ce630fd9`.
- Affected source: `pkg/server/server.go` and `pkg/stream/pipeline.go`.
- Existing protocol: the generated `RunComplete` message carried as the
  stream's `CommandComplete` packet.

The fork source follows the stock design but current Apple `main` has not been
rebased or tested for this unsubmitted handoff. No Apple external state was
changed; that recheck is mandatory at the publication gate.

## Expected Behavior

- After successful BuildKit execution, send exactly one terminal completion
  packet through the existing stream.
- Wait for the client request stream to finish, preserving cancellation.
- Keep ownership of the vendored client's progress/status channel with that
  client; do not close it separately.
- Preserve errors and normal progress ordering before terminal completion.

## Apple-Shaped Candidate

The candidate serializes outbound packets through a cancellation-aware `Send`
helper. The server runs the pipeline, sends the generated terminal packet when
BuildKit returns, and waits for the pipeline receive loop before returning.
The first commit removes the incorrect duplicate status-channel close.

The paired Container host handoff recognizes the terminal packet and finishes
its request half. The two small generic changes are intentionally kept in
separate repositories and can be reviewed independently.

## Acceptance Evidence

- `go test ./pkg/stream ./pkg/server -count=1` passes.
- `go vet ./pkg/stream ./pkg/server` and `git diff --check` pass.
- Focused coverage records 100% for new `Send` and `buildCompletePacket`.
- `PerformBuild` is the real BuildKit boundary and remains 0% unit
  instrumented; an exact BuildKit-backed runtime certificate supplies behavior
  proof without fabricating a client mock.

## Publication Gate

Keep this record local and `unsubmitted`. Before any Apple submission, recheck
current upstream source and overlaps, rebase the narrow source/test series,
run current stock focused and repository validation, then wait for the
programme-wide gate and explicit authorization.
