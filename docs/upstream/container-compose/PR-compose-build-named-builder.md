# Support named `compose build --builder`

## Summary

- Marks `build --builder` supported in the compose help surface.
- Forwards `ComposeBuildOptions.builder` to `container build --builder`.
- Keeps `build --print` Docker-compatible by omitting builder selection from generated bake JSON.
- Adds focused unit coverage for default and named builder forwarding.
- Updates the local-only Docker Compose parity script to verify both `default` and a non-default builder name.
- Adds runtime smoke coverage for a live named-builder build through the fork-backed `container` backend.

## Runtime Support

The paired stephenlclarke fork-backed `container` change adds `--builder` to `container build` and the `container builder start/status/stop/delete` lifecycle commands. `default` maps to the existing `buildkit` builder container; non-default names map to separate `buildkit-NAME` builder containers.

## Validation

```sh
swift test --disable-automatic-resolution --filter 'buildForwardsDefaultBuilderSelection|buildForwardsNamedBuilders'
make docker-compose-build-builder-parity
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeBuildUsesNamedBuilder
```

## Compatibility

Stock Apple `container` remains outside the supported Homebrew release lane for this feature. Runtime-backed Compose commands preflight for the stephenlclarke fork-backed runtime stack and point users at the project install instructions when the installed Apple components do not support the requested functionality.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `562e353a6b4b1b39fdd7b94668064977c2720e83`.
