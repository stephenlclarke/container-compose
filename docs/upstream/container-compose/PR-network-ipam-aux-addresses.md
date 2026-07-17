# Pull request: map IPv4 IPAM auxiliary address reservations

## Summary

- Map `ipam.config[].aux_addresses` values for the selected IPv4 pool to the fork runtime's generic address-reservation primitive.
- Carry them through the normalized model, direct network API, and dry-run
  `container network create --reserve-ip` rendering.
- Reject invalid, duplicate, and endpoint-conflicting values before side effects.
- Document the remaining custom-driver name and DNS limitation rather than silently claiming it as implemented.

## Commit tracking

- Container runtime: `408c89b300bba79bf0d90469bdd9cf36a9914fa0` merged as `5ee3649a589d56fb341d85fe9aa50d482cbfdee5` in `stephenlclarke/container`.
- Compose mapping: `feat/network-ipam-reserved-addresses` until this pull request is merged.

## Validation

```console
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter 'ComposeNormalizerTests|ComposeOrchestratorTests' -Xswiftc -warnings-as-errors
make fmt
make check
make test
```
