# Pull Request: retain VMNet allocation-range leases across service restart

## Summary

- Preserve durable network attachment allocations when a runtime session disconnects during service restart.
- Keep session-scoped allocation cleanup unchanged.
- Release durable state at explicit container deletion.
- Add focused IPv4/IPv6/idempotent cleanup coverage and retain a real Docker/Compose CLI certificate.

See the companion [issue handoff](ISSUE-network-ipam-allocation-range.md).

## Intended review delta

Apply signed commits `d7e5f5ddd831e0fe0cf025d606f1d2622eb6a4d2` and `ec286fca9bca2c4d9d732f6f898564d9f23e1eb6` from local branch `upstream/net-ipam-allocation-range-01` after a fresh overlap review against current `apple/container:main`.

The durable attachment path marks its allocation for retention on disconnect. The controller explicitly releases that allocation at container deletion. The separate session release route remains responsible for transient attachment lifecycle, so a stale disconnect cannot free a container-owned lease.

## Validation

On this MacBook Pro:

```console
swift test --enable-code-coverage --filter 'AttachmentAllocatorTest|DefaultNetworkServiceTest'
```

The focused suite passes 31 tests in two suites. `AttachmentAllocator.swift` reports 92.96% focused line coverage; the direct changed lifecycle paths are covered. The real release Compose/Container certificate passes the same-MBP Docker Compose `5.4.0` / Docker Engine `29.2.1` oracle for an IPv4 range, gateway, two auxiliary addresses, dynamic allocation, service restart retention, and project network removal.

## Compatibility and risk

- No public API or protocol schema changes.
- Durable allocations now match Docker's restart behavior instead of being released by session teardown.
- Session-scoped allocations remain reclaimable on disconnect.
- This delta does not implement multiple pools, custom drivers, IPv6 range semantics, global address spaces, or reconciliation after provider/controller failure.

## Publication gate

- [x] Local signed source/test candidate and focused coverage.
- [x] Source-matched release artifact and Docker CLI certificate.
- [x] Local fork issue and handoff record.
- [ ] Fresh stock-Apple rebase and overlap review.
- [ ] Stock focused and repository validation.
- [ ] Programme-wide publication gate and explicit authorization.
