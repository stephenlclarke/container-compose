# Pull Request

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change exposes process identifiers for one running container
through the same typed resource, XPC, API-service, runtime-client, and CLI
layers used by other container inspection operations.

The Apple-facing surface remains generic. It returns PID membership and offers
`container top` as a compact diagnostic command; Docker Compose service
selection and Docker's richer process table remain outside this repository.

Related issue draft:
[ISSUE-process-identifiers.md](ISSUE-process-identifiers.md).

## Commit Tracking

- Runtime/API/CLI implementation:
  `02a04fb372a6629ba02a14d34c8f9ac5b5a755df` on
  `stephenlclarke/container:handoff/process-identifiers`
  (`feat(runtime): expose container process identifiers`).
- Command-reference update: `bc5cd8d4dcbc159502e394bf343f2b9c2e2a181e` in `stephenlclarke/container`
  (`docs(top): document process identifier output`).
- Required lower-runtime commits:
  `d69f7e51c5ae9ecec6ad7fc4a6358b824cc515e7` and
  `aaa143b15f426912342cb4f29dc6a55065ba0651`, tracked in
  [the containerization handoff](../apple-containerization/PR-process-identifiers.md).
- Compose integration remains separate in
  [PR-compose-top-process-list.md](../process-list/PR-compose-top-process-list.md).

The handoff branch is based on `apple/container:main` and excludes the
`stephenlclarke` dependency pin. Prepare the Apple branch on the accepted
lower-runtime revision, then squash the implementation and focused
command-reference update.

## Implementation Details

- Added `ContainerProcesses` as a codable, sendable resource model.
- Added the runtime route from `LinuxContainer.processIdentifiers()` through
  the runtime XPC service and client.
- Added the API-service route and `ContainerClient.processes(id:)`.
- Allowed process reads for running containers and rejected other lifecycle
  states.
- Added `container top` with table and structured output formats.
- Registered all new routes in the existing service startup tables.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter ContainerProcessesTests
swift test --filter ContainerTopFormattingTests
make check
```

The resource test covers structured-data round trips and the formatting tests
cover populated and empty tables. Runtime behavior is exercised through the
lower-runtime tests and the `container-compose top` integration path.

## Dependency Notes

This pull request must stack on the `apple/containerization` process-identifier
primitive. Do not submit the stephenlclarke dependency URL or fork revision in
the Apple pull request.

## Remaining Risks

- PID membership can change immediately after the snapshot is returned.
- The current lower runtime does not expose UID, PPID, CPU, start time, TTY,
  elapsed time, or command text. Those fields require a separate generic process
  metadata API and are not synthesized here.
