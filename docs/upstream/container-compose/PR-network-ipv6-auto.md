# Pull Request: normalize automatic Compose IPv6 enablement

## Summary

- Accept `networks.<name>.enable_ipv6: true` without requiring an explicit IPv6
  IPAM subnet.
- Reject `enable_ipv6: false` before runtime side effects because vmnet cannot
  suppress its automatic IPv6 allocation.
- Add Go, Swift, macOS runtime, and Docker Compose V2 parity coverage.
- Correct the network/IPAM status ledger and the older project-network-options
  handoff.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The previous normalizer treated `enable_ipv6: true` without an explicit subnet
as unsupported, even though the generic vmnet backend automatically assigns an
IPv6 prefix in that case. It also let `enable_ipv6: false` through when no
subnet was supplied, despite the runtime assigning IPv6 anyway. That was both
too strict for the enabled case and silently incorrect for the disabled case.

Docker Compose exposes `enable_ipv6` as the IPv6 address-assignment control:
<https://docs.docker.com/reference/compose-file/networks/#enable_ipv6>.

## Commit Tracking

- Compose code and tests:
  [`55d00074864d21c70c9b03995886fbc9cf9e57de`](https://github.com/stephenlclarke/container-compose/commit/55d00074864d21c70c9b03995886fbc9cf9e57de)
  (`fix(network): normalize automatic IPv6 enablement`), signed by
  `stephenlclarke@mac.com`.
- Apple/fork code: none. This is a Compose-layer correction that consumes the
  existing generic vmnet behavior; it adds no Docker-specific API to a fork.
- Upstream issue handoff: [ISSUE-network-ipv6-auto.md](ISSUE-network-ipv6-auto.md).

## Implementation Details

- `projectNetworkValues` now marks only an explicit IPv6 disable request as
  unsupported. `enable_ipv6: true` requires no extra runtime argument because
  vmnet's generic create path supplies the automatic prefix.
- Go tests cover enabled-without-subnet, disabled-without-subnet, and the
  existing disabled-with-explicit-subnet case.
- Swift normalizer tests assert the public normalized model. The live macOS
  integration creates a project network and verifies its runtime
  `status.ipv6Subnet` is non-empty.
- `Tools/parity/check-compose-network-ipv6.sh` verifies Docker Compose V2
  config preserves both boolean values, container-compose accepts the enabled
  case, and container-compose rejects the disabled case before side effects.

## Docker Compose Compatibility Notes

Supported on macOS:

- `enable_ipv6: true` with an explicit IPv6 subnet.
- `enable_ipv6: true` without an explicit subnet, using vmnet's automatic IPv6
  prefix allocation.

Still unavailable:

- `enable_ipv6: false`; the runtime has no generic control to disable automatic
  IPv6 allocation.
- IPv6 gateway, allocation range, and auxiliary-address options; multiple IPv6
  pools; and the separate IPv4-disable gap.
- Embedded DNS and service discovery. This slice makes no claim about either.

## Local Validation

```bash
cd Tools/compose-normalizer
go test -coverprofile=/tmp/container-compose-network-ipv6.coverprofile ./...
go tool cover -func=/tmp/container-compose-network-ipv6.coverprofile

cd ../..
make swift-test SWIFT_TEST_RUN_FLAGS="--filter 'normalizerMapsAutomaticIPv6Enablement|normalizerMarksIPv6DisablementUnsupported'"
make docker-compose-network-ipv6-parity
make lint
```

The focused macOS runtime test passed against a locally built matching
`stephenlclarke/container` revision after supplying temporary build provenance
for that test run. The provenance override only satisfied the plugin's version
guard; it did not change production source, runtime behavior, or release pins.

## Handoff Status

- [x] The code slice is independently tested locally.
- [x] The Docker Compose V2 parity fixture passed locally.
- [x] The macOS live runtime test passed locally.
- [x] The fork boundary is Apple-shaped: no fork change was needed.
- [x] No push, prerelease, or stable release accompanies this lone slice.
