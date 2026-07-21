# Pull Request: preserve colons in container copy paths

## Summary

- Split a `container:path` reference once, at its identifier/path boundary.
- Preserve subsequent colons in the POSIX guest path.
- Cover the parser and the live macOS copy-out path.

## Intended Review Delta

Apply `f03ae577d1c45e31ee6934cb020addb80334cf2d` from
`stephenlclarke/container`.

The change is restricted to `Application.ContainerCopy.parsePathRef` and its
tests. It adds no Compose type, Docker-specific runtime behavior, or path
translation layer.

## Upstream context

This resolves [apple/container#1969](https://github.com/apple/container/issues/1969).
The syntax matches `docker cp`: only the first colon separates the container
identifier from its path.

## Code Map

- `Sources/ContainerCommands/Container/ContainerCopy.swift`: uses a
  first-separator split while retaining empty-field validation.
- `Tests/ContainerCommandsTests/ContainerCopyCommandTests.swift`: verifies a
  timestamp-shaped path retains both colons.
- `Tests/IntegrationTests/Containers/TestCLICopyCommand.swift`: copies a
  colon-named guest file back to the host and verifies its content.

## Validation

```console
swift test --filter \
  'ContainerCopyCommandTests/copyPathReferencePreservesColonsInContainerPaths'
make test
make coverage-unit
make check
```

The focused test and complete 1,114-test unit suite passed. Unit coverage
reported 38.06% line coverage (13,247 / 34,806), and formatting/license checks
passed. The integration test is compiled and registered in the macOS
integration suite. A source-matched isolated integration attempt timed out
while starting its local apiserver, before a guest was created; cleanup
confirmed the service stopped. Run the committed test on a healthy macOS
Virtualization/XPC runner before offering this upstream.

## Handoff Status

No Apple remote has been pushed. The signed Stephen-owned fork commit is ready
for maintainer review once the live integration rerun is green.
