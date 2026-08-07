# Issue: isolate candidate public Docker socket service ownership

## Problem description

`container-compose` could create a marker-protected app root, but the
Container services used stable per-user launchd/Mach identifiers. The runner's
cleanup invoked `container system stop`, so an otherwise isolated candidate
could stop an unrelated user-owned `devcontainer-engine`. That made public
Docker-socket validation unsafe and could leave a user runtime unavailable.

The user-visible contract is narrower than Docker logging or Compose parity:
a candidate must own a distinct public Docker socket and service set, return
through an unmodified Docker CLI, then remove only its own services. A
pre-existing default-namespace runtime must remain healthy throughout.

## Resolution

Signed local Compose commit `40d109db071cd98f2b37300e417e478f00213b3c`
derives a bounded `CONTAINER_SERVICE_NAMESPACE` from a marker-protected
candidate root and UID, validates the namespace-derived Engine socket before
starting services, rejects the legacy global-stop helper, and scopes teardown
to the selected namespace. The paired Container implementation is signed local
commit `c740a8f6a79ce176d03a941f49cdfe7350625a71`.

The exact candidate lifecycle used namespace
`io.github.stephenlclarke.container-compose.runtime.a46377784f5464874269b3ca`
and socket
`/tmp/container-engine-501-8806c2d9ecceef7b17c5576b/docker.sock`. It answered
`29.7.1|29.2.1|linux` through Docker CLI, then removed its socket and every
candidate service. The user `devcontainer-engine` remained running and its
socket returned `29.7.1|1.1.0|linux` both before and after cleanup.

## Focused evidence

- `Tools/ci/test_run_with_container_runtime.py` passed 14 focused tests with
  99% branch coverage for the runner.
- The candidate root `/private/tmp/ctr-isopub4.Id3j22` is marker-protected;
  its retained preflight and runner log prove source, dependency, binary,
  guest, root, socket, lifecycle, and cleanup fingerprints.
- The source-built lifecycle exited `0` after 722 seconds. That diagnostic
  debug timing is not comparable-performance evidence.
- The paired Container focused namespace/start/stop suite passed 19 tests,
  with `ContainerServiceNamespace.swift` at 100% line/function/region
  coverage.

## Scope and tracking

This closes only the lower-runtime service-ownership defect. It does not
certify a logging driver, Compose project, general REST surface, or
comparable-or-better performance. The next queued public contract is
`LOGGING-FLUENTD-TCP-ACK-REST-01`, which must use a new exact-fingerprint
namespace-aware root.

The durable contract record is
[RUNTIME-ISOLATED-PUBLIC-SOCKET-01](../../parity/handoffs/RUNTIME-ISOLATED-PUBLIC-SOCKET-01.md).
No upstream or Apple publication is authorised; this local handoff is retained
for review only after the programme-wide publication boundary.
