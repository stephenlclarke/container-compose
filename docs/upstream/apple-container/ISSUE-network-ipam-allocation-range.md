# Issue: retain VMNet allocation-range leases across service restart

## Steps to reproduce

Create a VMNet network with IPv4 subnet `192.168.200.0/24`, allocation range `192.168.200.128/25`, gateway `192.168.200.1`, and an in-range auxiliary reservation at `192.168.200.130`. Start a dynamically addressed workload, then restart it through a Compose lifecycle.

Before the local correction, disconnecting the old runtime attachment released the durable allocation. A subsequent start could allocate a different address even though Docker preserves the endpoint's network allocation across service restart.

## Problem description

Runtime attachment cleanup needs to distinguish a durable container attachment from a session-scoped request. Disconnecting a durable attachment must preserve its allocation and MAC/IPv6 identity until explicit container deletion releases it. Session-scoped allocations still need cleanup when their client disconnects.

The implementation must:

1. Track whether an attachment allocation is retained on disconnect.
2. Release retained state only through explicit container deletion.
3. Preserve existing session-scoped release behavior.
4. Cover IPv4/IPv6 and idempotent release cleanup paths.
5. Prove the resulting behavior through a real Compose CLI lifecycle rather than only a fabricated XPC call.

## Local candidate and validation

The proposed Apple-shaped delta is signed Container commits `d7e5f5ddd831e0fe0cf025d606f1d2622eb6a4d2` and `ec286fca9bca2c4d9d732f6f898564d9f23e1eb6` on local branch `upstream/net-ipam-allocation-range-01`. The focused source suite passes 31 tests; `AttachmentAllocator.swift` has 92.96% focused line coverage. The release Compose/Container certificate is retained at `/private/tmp/container-ipam-allocation-range-release.ZgE2Ll/evidence` and passes the Docker Compose `5.4.0` / Docker Engine `29.2.1` allocation-range, auxiliary-reservation, restart-retention, and cleanup oracle.

## Tracking

- Local tracker: [stephenlclarke/container#83](https://github.com/stephenlclarke/container/issues/83), commented and closed as completed after the release certificate.
- Compose contract handoff: [NET-IPAM-ALLOCATION-RANGE-01](../../parity/handoffs/NET-IPAM-ALLOCATION-RANGE-01.md).
- No Apple issue or pull request has been created. This is a local unsubmitted handoff pending the programme-wide publication boundary and explicit authorization.
