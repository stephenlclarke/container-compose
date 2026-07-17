# Pull request: support numeric Compose supplemental groups

## Summary

- Map numeric service `group_add` values into the typed service process configuration.
- Render the same values as repeatable `container run --group-add` arguments for one-off containers.
- Reject named values before side effects and document the image-aware runtime capability that remains necessary.
- Align the parity ledger and README with the supported numeric subset.

## Commit tracking

- Container runtime: `789125a008e7e7716afd27fe311c2686594b8d5b` merged as `77c70043a393dede0053738b4c32c486dcb0e578` in `stephenlclarke/container`.
- Compose mapping: `feat/supplemental-groups` until this pull request is merged.

## Validation

```console
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter 'ComposeOrchestratorTests' -Xswiftc -warnings-as-errors
make fmt
make check
make test
```
