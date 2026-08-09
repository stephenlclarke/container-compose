# Pull Request: certify retained Compose IPv4 allocation-range leases

## Summary

- Build the release Compose binary against the exact local Container stack when local overlays are supplied.
- Retain the Docker/Container Compose Bash CLI fixture for allocation-range, gateway, auxiliary-reservation, restart, and cleanup behavior.
- Record the matched release artifact and local Apple-shaped runtime retention delta.

See the companion [issue handoff](ISSUE-network-ipam-allocation-range.md).

## Motivation and context

The Compose model alone was insufficient evidence because runtime session teardown released a durable VMNet allocation. Docker preserves the allocation through `compose restart`. The effective lower-runtime fix is deliberately isolated in Container; the Compose build change makes a release candidate use that exact local source graph instead of stale remote dependency resolution.

## Testing

- [x] `python3 Tools/ci/test_build_release_local_stack.py -v` passes 2 tests.
- [x] `make build-release` with exact local Container, Containerization, and Engine API overlays succeeds.
- [x] The strict Docker/Compose Bash CLI fixture passes with a complete source/dependency/binary/guest/root fingerprint.
- [x] The focused Container attachment suite passes 31 tests; `AttachmentAllocator.swift` has 92.96% focused line coverage.
- [x] Final documentation, registry, and diff checks are required before this checkpoint is considered clean.

## Compatibility and risk

The release-build overlay is transactional and restores `Package.resolved`; default release builds retain their normal dependency behavior. The runtime correction preserves durable allocations only through the existing container deletion lifecycle. Multiple pools, custom drivers, IPv6 allocation ranges, reconciliation, and release performance remain outside this narrow contract.

## Publication status

No pull request has been opened from this handoff. The signed local changes and evidence are retained for later review after the programme-wide publication boundary and explicit authorization.
