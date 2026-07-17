# Pull request: support Compose CPU shares

## Summary

- Remove `cpu_shares` from the unsupported-runtime ledger.
- Validate zero-as-default and non-zero weights of at least `2` before side
  effects.
- Carry the typed value in the service-create plan.
- Render it for `up`, `create`, and one-off `compose run` containers.
- Update parity status, fork pins, and Apple-shaped handoff drafts.

## Commit tracking

- Containerization prerequisite: `8e4cf75af5d828ce111474df956f3c5cf7407757`
  merged as `d5e6c22d48cfea0fea0958b8079b7df3fb399a2a` in
  `stephenlclarke/containerization`.
- Container runtime: `d1f3aee65f3f53d959825ef91d99ccbedf3492f9` merged as
  `0c80ec848da79747f0c2c0c121d85f9876d6b919`, with
  `f4af7bc8e18dac2f356e4530f24af1efd35a914f` merged as
  `4b567a52b626fa6d3d786dc545e4f9d905f33bce`, in
  `stephenlclarke/container`.
- Compose mapping: `feat/cpu-shares` until this pull request is merged.

## References

- <https://github.com/compose-spec/compose-spec/blob/master/spec.md#cpu_shares>
- <https://docs.docker.com/engine/containers/resource_constraints/#configure-the-default-cfs-scheduler>

## Validation

```console
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter 'ComposeOrchestratorTests' -Xswiftc -warnings-as-errors
make fmt
make check
make test
markdownlint docs/upstream
```
