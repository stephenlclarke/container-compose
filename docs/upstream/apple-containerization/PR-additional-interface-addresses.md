# Pull request: support additional guest interface addresses

## Summary

- Add `additionalIPAddresses` to the generic interface model.
- Configure each typed IPv4 or IPv6 CIDR before bringing the guest link up.
- Permit the guest RPC endpoint to handle an IPv6-only address request.
- Preserve the existing primary-address and routing behavior.

## Intended review delta

This draft is constructible from `stephenlclarke/containerization` commit
`e70999db4f09f5408a2429739f08f98c55e33d16`.

## Implementation details

The change is deliberately a generic VM-network capability. It neither refers
to Compose nor decides which addresses are link-local. The protocol default
implementation maintains source compatibility for legacy agents: IPv4
supplementary addresses use the existing address shape and an IPv6-only request
requires an agent with the new generic operation.

## Upstream context

No matching open `apple/containerization` issue or pull request was found on
2026-07-16. `apple/container#1034` is related IPv6 work but is not a duplicate.

## Validation

```sh
make check
swift test --filter InterfaceTests --disable-automatic-resolution -Xswiftc -warnings-as-errors
make test
make vminitd
```

## Handoff status

No Apple-owned remote has been pushed. The Stephen-owned fork implementation is
ready for Apple-maintainer review.
