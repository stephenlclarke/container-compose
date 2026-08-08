# LOGGING-SPLUNK-HEC-REST-01 Handoff

## State

`Active` — this is the one current user-visible vertical contract. The Splunk
required-option lifecycle is already `Verified` separately; no Docker CLI
public-socket HEC delivery certificate exists yet.

## User-visible contract

With a valid `splunk-url` and `splunk-token`, an unmodified Docker CLI must run
a cache-disabled `splunk` logging container and send its ordered stdout and
stderr records to a local Splunk HEC-compatible HTTP receiver. The contract will
use only the Docker behavior measured in this slice for endpoint path,
authorization header, payload shape, record order, process exit, inspect
projection, and owned cleanup. Receiver data and routine diagnostics must not
disclose the supplied token outside the expected Authorization header capture.

## Pinned Docker oracle

Same-MBP Colima with Docker CLI `29.7.1`, Engine `29.2.1`, API `1.53`, and
`alpine:3.20`. The first action is a marker-protected receiver-root observation
using a minimal local HEC-compatible endpoint reachable as
`host.docker.internal`. Its result becomes the immutable oracle for the
candidate fixture; no guessed payload contract is accepted.

## Affected repositories and pins

- `container-compose` local `main` starts at signed `81e6ed7f`.
- Matched Container source starts at signed
  `bf2d6de19e0924fa3cd08fe20276c987d785c060` on
  `upstream/docker-wait-acknowledgement-01`.
- Existing detached compatible inputs are Containerization
  `38d9c695e7a6915e5ce45d12c893dc323a661af7` and Engine API
  `afb8a8f68ed56829b669c95cbddb488a68dc9175`.

No remote, dependency pin, issue, PR, or upstream change is authorized.

## Focused proof

1. Capture one Docker reference with a marker-protected local HTTP receiver.
2. Implement only the fixture or source correction that a measured mismatch
   requires, with a focused provider/API test where code changes.
3. Run the fixture through one fresh isolated public Container socket with an
   exact fingerprint covering source, detached dependencies, binaries,
   guest/init archive, harness, receiver root, and runtime root.

## Completion criteria

- Docker and candidate agree on the selected endpoint, authorization, decoded
  payload/order, exit state, inspect driver projection, and owned cleanup.
- The candidate exits cleanly and never hangs or exceeds a bounded liveness
  timeout.
- Any changed code has direct focused tests; coverage should approach 90% when
  disk headroom permits instrumentation.
- A clean signed local checkpoint records the evidence. Comparative performance
  is intentionally deferred.

## Blocker criteria

A Docker oracle that cannot be captured safely, an exact-fingerprint mismatch,
a hang, timeout, cleanup failure, or a measured reference/candidate behavioral
difference is blocking. After two evidence-based corrections without a behavior
or blocker-evidence delta, preserve the root and hand off instead of retrying.

## Safe handoff

Retain only marker-protected roots created by this slice and the Docker oracle
record. Do not modify the user-owned devcontainer runtime. The active slice
START thread is `1786218665.126109`.
