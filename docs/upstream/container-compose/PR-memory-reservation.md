# Pull request: support Compose memory reservations

## Summary

- Remove `mem_reservation` from the unsupported-runtime ledger and normalize
  its Docker Compose local-mode Deploy alias,
  `deploy.resources.reservations.memory`, through the same path.
- Validate non-negative byte values, zero-as-default, and the required
  reservation-below-explicit-hard-limit relationship before side effects.
- Carry the typed value in the service-create plan.
- Render it for `up`, `create`, and one-off `compose run` containers.
- Update parity status, fork pins, and Apple-shaped handoff drafts.

## Commit tracking

- Containerization prerequisite: `bfd6c0da31391e32d531db53cc8df56cbd4810ac`,
  range-safe in `b0614cbf986dcca48183aa1ff0e4df8561302c85`, merged as
  `c5ca0366d88cf77eefb857b7b3d7f2d098070bab` in
  `stephenlclarke/containerization`.
- Container runtime: `089f55dbc3b85e814fc81464854852d887de86b9` merged as
  `d5774583697dc239b140ae38cc79fa9259753061` in
  `stephenlclarke/container`.
- Service-form Compose mapping: `feat/memory-reservation` until this pull
  request is merged.
- Deploy-alias Compose mapping: tracked in
  [PR-deploy-memory-reservation-projection.md](PR-deploy-memory-reservation-projection.md).

## Reference

- <https://docs.docker.com/engine/containers/resource_constraints/>

## Validation

```console
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter 'ComposeOrchestratorTests' -Xswiftc -warnings-as-errors
make fmt
make check
make test
markdownlint docs/upstream
```
