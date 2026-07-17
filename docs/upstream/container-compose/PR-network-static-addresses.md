# Pull request: support Compose static network endpoint addresses

## Summary

- Stop classifying endpoint `ipv4_address` and `ipv6_address` as unsupported.
- Validate the requested addresses before Compose creates resources.
- Render static addresses through matched `--network NAME,ip=...,ip6=...`
  options for `up`, `create`, and one-off `run`.
- Pin the matched Container runtime that reserves requested addresses.
- Update the parity ledger and exercise mapping, external networks, and
  no-side-effect rejection paths.

## Compose policy

For a Compose-managed network, the requested address must match the declared
IPAM subnet. IPv4 requests must also be allocatable hosts under the runtime's
existing network allocation policy. External networks have no trustworthy
project-local IPAM declaration, so Compose validates the address spelling and
defers network-range and collision ownership to the runtime.

References:

- <https://docs.docker.com/reference/compose-file/services/#ipv4_address>
- <https://docs.docker.com/reference/compose-file/services/#ipv6_address>

## Commit tracking

- Container runtime: `dc18f02c0fa8e9af391dabde19be283d4b8b648e` merged as
  `bb7d633449a38f7f0b00079b6e51da47326d490f`.
- Compose mapping: `feat/network-static-addresses` until this pull request is
  merged.

## Validation

```sh
cd Tools/compose-normalizer && go test ./...
swift test --filter ComposeOrchestratorTests --disable-automatic-resolution -Xswiftc -warnings-as-errors
make check
make test
```

## Handoff status

No Apple-owned remote has been pushed. The generic runtime proposal and the
Compose compatibility mapping are deliberately separate for maintainer review.
