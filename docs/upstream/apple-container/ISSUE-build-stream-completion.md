# Terminal Build Completion Does Not Finish the Client Request Stream

## Problem

A bidirectional build request can remain live after successful BuildKit work.
The builder peer sends the protocol's terminal `CommandComplete` packet, but
the Container host keeps its request half open while waiting for the peer to
finish. A peer that correctly waits for request EOF before ending its response
then forms a duplex completion cycle.

This is a generic build-protocol lifecycle problem. It is not Compose- or
Docker-specific, and it must not be solved by transport timeout heuristics.

## Reproduction Boundary

- Candidate branch: `upstream/net-ipv6-only-runtime-integration-02`.
- Signed commit: `a661e67c8e7713483eb448493c7b4a35f346d9b3`.
- Affected host source:
  `Sources/ContainerBuild/BuildPipelineHandler.swift`.
- Terminal packet: `Com_Apple_Container_Build_V1_RunComplete` represented by
  the existing `Builder.Error.buildComplete` lifecycle error.
- Observed effect: a source-matched runtime build reaches successful BuildKit
  export but cannot finish the two-sided stream without a terminal receive-path
  transition.

The candidate derives from the stock protocol shape, but current Apple `main`
must be rechecked immediately before any publication. No Apple issue, pull
request, branch, comment, or push was created or changed for this handoff.

## Expected Behavior

- Treat a received terminal completion packet as a normal terminal build
  outcome, not an ordinary progress packet.
- Finish the host request stream after the receive loop completes.
- Preserve cancellation, nonterminal progress, failure propagation, and wire
  compatibility.
- Do not add Docker-, Compose-, or fork-specific policy to the generic API.

## Apple-Shaped Candidate

The signed candidate adds a small terminal-packet helper to the existing
receive loop and uses `defer` to finish the request sender. It changes only the
generic host lifecycle and its narrow completion regression tests.

The paired builder-shim handoff supplies the peer's terminal packet and waits
for request EOF. It should land first or be integrated as an explicitly
compatible pair; neither side should rely on a timeout to break the cycle.

## Acceptance Evidence

- `BuildPipelineCompletionTests` passes 2/2 at the exact candidate revision.
- Instrumented Swift coverage executes both branches of the changed
  `throwIfBuildComplete` helper (100% of its executable lines).
- An exact source/dependency/binary/guest fingerprint runtime certificate
  completes a real BuildKit build and then exercises a Compose IPv6-only
  create/start/inspect/`ping -6`/cleanup flow.
- The local Stephen issue records the correction and completion evidence:
  [container#82](https://github.com/stephenlclarke/container/issues/82).

## Publication Gate

Keep this handoff local and `unsubmitted` until the programme-wide publication
gate. At that point, reproduce against current stock Apple `main`, perform a
fresh overlap review, rebase the narrowest applicable source/test delta, run
the stock focused and repository gates, and obtain explicit authorization.
