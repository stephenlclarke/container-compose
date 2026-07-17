# Pull request: support Compose IPv4 IPAM allocation ranges

## Summary

- Stop classifying `ip_range` on the single supported IPv4 IPAM pool as unsupported.
- Normalize the value into the Compose project model.
- Validate the range before resource creation without narrowing valid static-address checks.
- Map the value to the direct runtime configuration and dry-run command rendering.
- Pin the matched generic runtime implementation and update the parity ledger.

## Compose policy

The supported subset is one IPv4 subnet with optional gateway and allocation range. The range limits dynamic allocation only, matching Docker Compose semantics; explicit IPv4 addresses remain governed by the parent subnet. IPv6 allocation ranges, additional IPv4 pools, and IPAM options remain unsupported because the runtime has no matching implementation.

## Commit tracking

- Container runtime: `7bf522fb808ee2517d917881421180d88d837704` merged as `ee63145e7f0f6d7023d6cec64b1019077b0461e4` in `stephenlclarke/container`.
- Compose mapping: `feat/network-ipam-allocation-range` until this pull request is merged.

## Validation

```sh
cd Tools/compose-normalizer && go test ./...
swift test --filter 'ComposeNormalizerTests|ComposeOrchestratorTests' --disable-automatic-resolution -Xswiftc -warnings-as-errors
make check
make test
```

## Handoff status

No Apple-owned remote has been pushed. The generic runtime proposal and the Compose compatibility mapping remain separate for maintainer review.
