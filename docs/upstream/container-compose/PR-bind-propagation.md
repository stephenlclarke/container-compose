# Support bind propagation mount options

## Summary

- Preserves service bind `propagation` in the normalized mount model.
- Stops treating `bind.propagation` as an unsupported service volume field.
- Maps supported propagation values to Apple runtime short `--volume` options for `up`, `create`, and `run`.
- Adds Go normalizer tests, Swift model/orchestrator tests, and a local-only Docker Compose V2 parity target.
- Updates README, status, design, build docs, and handoff notes.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Real monitoring stacks commonly mount host filesystem views into exporters with `bind.propagation: rslave`. Docker Compose preserves that option and passes it to Docker Engine. `container-compose` previously rejected the field during model validation, which blocked otherwise parseable projects before Apple runtime handoff.

The current Apple lower-runtime path already carries generic mount options into OCI bind mounts. The Compose-owned work is to preserve compose-go's propagation field, validate the Docker Compose value set, and render the option through the existing `container --volume` argument path.

## Commit Tracking

- Compose code commit: `5fbe9f0937d8966c6bca099035be604d47e15dd6` in `stephenlclarke/container-compose` (`feat(mounts): support bind propagation`).
- Apple/container code commit: see `docs/upstream/apple-container/PR-bind-propagation-volume-option.md`.
- No apple/containerization commit is required for this slice; existing `Mount.options` and `FileMountContext.ociBindMounts()` preserve the option.

## Implementation Details

- Added `bindPropagation` to the Go normalizer JSON and Swift `ComposeMount`.
- Added `bindPropagationValue` in the normalizer and removed `bind.propagation` from unsupported mount-field reporting.
- Added renderer validation for the six Docker Compose bind propagation values.
- Updated short-volume argument rendering so read-only and propagation options are emitted together, for example `:ro,rslave`.
- Kept unsupported handling for other advanced fields such as `bind.recursive`, `bind.selinux`, and `consistency`.
- Added `Tools/parity/check-compose-bind-propagation.sh` and `make docker-compose-bind-propagation-parity`.

## Validation

```sh
go test ./...
swift test --disable-automatic-resolution --filter 'normalizesBindCreateHostPathPolicy|createMapsBindPropagationToVolumeOptions|upMapsBindPropagationToVolumeOptions|runMapsBindPropagationValuesToVolumeOptions|runRejectsUnsupportedBindPropagationValuesBeforeRuntime|runRejectsAdvancedMountFieldsAsAppleContainerGap'
bash -n Tools/parity/check-compose-bind-propagation.sh
shellcheck Tools/parity/check-compose-bind-propagation.sh
make docker-compose-bind-propagation-parity
make check
make ci
git diff --check
```

## Compatibility

This change makes `container-compose` more Docker Compose compatible for host-observability fixtures and monitoring stacks. The plugin still does not promise that every host path in those fixtures is portable to macOS or to Apple Linux VMs; it only stops rejecting the supported bind propagation option and forwards it to the runtime.

## Remaining Risks

- Apple/container accepts short `--volume` option strings generically. A future typed mount API may prefer a structured propagation field.
- Host filesystem propagation behavior ultimately depends on the Linux VM mount stack and host share semantics.
