# Pull request: support Compose network interface names

## Summary

- Stop classifying network `interface_name` as unsupported.
- Render the preserved value as a matched runtime network attachment option.
- Pin Container and Containerization to the merged guest-name implementation.
- Update the parity ledger and add an orchestration test.

## Motivation and context

Compose already preserves the field through `compose-go`; rejecting it at the
runtime boundary was an avoidable gap once the generic guest-interface naming
primitive was available in the matched Stephen-owned stack.

This Compose slice intentionally owns only the Docker/Compose-shaped mapping.
The Apple-shaped code lives in the separate Containerization and Container
handoffs.

## Implementation details

`networkAttachmentArgument` now adds `interface=VALUE` after existing alias,
MAC, and MTU options. Empty names retain the prior no-op behavior. Compose
rejects commas before it renders the delimiter-based attachment value; the
generic runtime validates other non-empty requested names.

## Validation

```sh
go test ./Tools/compose-normalizer
swift test --filter runMapsInterfaceNamesToRuntimeNetworkAttachments
make test
make check
make docker-compose-parity
```

## Commit tracking

- Containerization backend: `bd9995b38a7e8abfc5ccfff9ea1e9f00eb895ac3`.
- Container bridge: `180374da8b4a6e1965ebf1c9b0b4a3d7ebfccb37`.
- Compose mapping: `feat/network-interface-name` in
  `stephenlclarke/container-compose` until its merge commit is created.

## Handoff status

No Apple-owned remote has been pushed. These drafts are ready for the final
Apple-maintainer review gate after stack-level validation.
