# Pull request: support Compose IPv4 IPAM gateways

## Summary

- Stop classifying a gateway on the single supported IPv4 IPAM pool as unsupported.
- Normalize the gateway into the Compose project model.
- Validate the gateway and reject static endpoint addresses that reuse it before resource creation.
- Map the value to the direct runtime configuration and dry-run command rendering.
- Pin the matched generic runtime implementation and update the parity ledger.

## Compose policy

The supported subset is one IPv4 subnet with one optional IPv4 gateway. The gateway must be inside that subnet and cannot be the network or broadcast address. IPv6 pool gateways remain unsupported because the runtime does not expose a matching configuration primitive.

## Commit tracking

- Container runtime: `8152d72970e7d08b5cb777360eb787849feb6c94` merged as `741ca823e9fdd6992c28c1ef4005fe174e428705` in `stephenlclarke/container`.
- Compose mapping: `feat/network-ipam-gateway` until this pull request is merged.

## Validation

```sh
cd Tools/compose-normalizer && go test ./...
swift test --filter 'ComposeNormalizerTests|ComposeOrchestratorTests' --disable-automatic-resolution -Xswiftc -warnings-as-errors
make check
make test
```

## Handoff status

No Apple-owned remote has been pushed. The generic runtime proposal and the Compose compatibility mapping remain separate for maintainer review.
