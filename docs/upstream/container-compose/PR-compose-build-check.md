# Support `compose build --check`

## Summary

- Stops rejecting `compose build --check`.
- Marks `build --check` as supported in help.
- Adds `check` to `ComposeBuildOptions`.
- Forwards `--check` to `container build`.
- Skips post-build image push in check mode.
- Renders `build --print --check` bake targets with `call: "lint"` and no image output.
- Adds unit coverage and a local-only Docker Compose parity target.

## Motivation

Docker Compose V2 exposes `build --check` as a BuildKit lint/config validation mode. With fork-backed `container build --check` available, the plugin can now support the Compose option without side effects.

## Validation

```sh
swift test --disable-automatic-resolution --filter 'buildPrintOptionIsShownAsSupported|buildPrintFlagParses|buildCheckForwardsCheckFlagAndSkipsPush|buildPrintCheckRendersLintBakeCallWithoutOutput'
make docker-compose-build-check-parity
```

The parity target reuses Docker Compose's upstream `pkg/e2e/fixtures/build-test/minimal` fixture and mutates only the temporary Dockerfile copy to trigger BuildKit's `FromAsCasing` lint rule. For live runtime validation against the fork-backed build backend:

```sh
CONTAINER_COMPOSE_BUILD_CHECK_LIVE=1 make docker-compose-build-check-parity
```

## Related Work

- Named builder selection is covered by the later fork-backed `build --builder NAME` slice.
