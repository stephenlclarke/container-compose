# Support named build builders

## Summary

- Adds a shared builder-name resolver in `ContainerBuild.Builder`.
- Adds `--builder` to `container build`.
- Adds `--builder` to `container builder start`, `status`, `stop`, and `delete`.
- Starts and dials the selected builder container instead of hard-coding `buildkit`.
- Keeps `default` mapped to the existing `buildkit` builder container.
- Adds unit coverage for builder-name resolution and CLI parsing.
- Adds CLI integration coverage for starting, using, stopping, and deleting a named builder.

## Compatibility

The default builder path is unchanged. Non-default names create separate builder containers named `buildkit-NAME`, which keeps the implementation local to the current runtime API and leaves a future upstream Buildx remote-builder integration path open.

## Validation

```sh
swift test --disable-automatic-resolution --filter 'BuilderNameTests|BuildCommandTests'
make integration INTEGRATION_TEST_SUITES=CLIBuilderLifecycleTest.testNamedBuilderStartBuildStopDelete
```
