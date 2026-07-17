# Pull request: support named and numeric Compose supplemental groups

## Summary

- Map numeric IDs and named service `group_add` values into the typed service process configuration.
- Preserve supplemental group names for guest-image `/etc/group` resolution, including healthcheck processes.
- Render the normalized values as repeatable `container run --group-add` arguments for one-off containers.
- Reject empty values and numeric IDs outside the `UInt32` range before side effects.
- Align the parity ledger with complete `group_add` support.

## Commit tracking

- Containerization prerequisite: `bf487e2` merged as `d34c67e2f0fce3ffa790630df6b803c014507560` in `stephenlclarke/containerization`.
- Container runtime: `c5625a3` merged as `ff04c728133ea4ef6a0e003115acff2bee03e941` in `stephenlclarke/container`.
- Compose mapping: `feat/named-supplemental-groups` until this pull request is merged.

## Validation

```console
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter 'ComposeOrchestratorTests' -Xswiftc -warnings-as-errors
make fmt
make check
make test
```
