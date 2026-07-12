# Pull request: expose container process metadata

<!-- markdownlint-disable MD013 -->

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change exposes process metadata for one running container through the same typed resource, XPC, API-service, runtime-client, and CLI layers used by other container inspection operations.

The Apple-facing surface remains generic. It returns process rows and offers `container top` as a compact diagnostic command; Docker Compose service selection remains outside this repository.

Related issue draft:
[ISSUE-process-identifiers.md](ISSUE-process-identifiers.md).

## Commit Tracking

- Runtime/API/CLI implementation:
  `b8c45d53720a11a5247577e3975e0d3fc52e614d` in
  `stephenlclarke/container` (`feat(runtime): surface container process
  metadata`).
- Required lower-runtime commit:
  `58c7eb72e1a6c1b17d8754c3593ebd0ad141193a`, tracked in
  [the containerization handoff](../apple-containerization/PR-process-identifiers.md).
- Required source-backed init-image support:
  `b478439e81c3ceddd58ef4be65d4c948bc1fa4f1` in
  `stephenlclarke/container` (`fix(build): build source-checkout init images
  safely`) and `d82fc5c24d48fffe2f48c8144642ab6fcf5299e0` in
  `stephenlclarke/container` (`fix(build): clean copied init sources`), tracked
  in [PR-containerization-branch-init.md](PR-containerization-branch-init.md).
- Required matched init-image reference support:
  `d03f81b4968d9f33914db1d77e00ce9f43178d00` in
  `stephenlclarke/container` (`build(init): install matched vminit image
  refs`), tracked in
  [PR-containerization-branch-init.md](PR-containerization-branch-init.md).
- Compose integration is tracked in
  [PR-compose-top-process-list.md](../process-list/PR-compose-top-process-list.md).

The Apple pull request should stack on the accepted lower-runtime revision. Do not submit the `stephenlclarke` dependency URL or fork revision in the Apple pull request.

## Implementation Details

- Extended `ContainerProcesses` with typed `ContainerProcessInfo` rows while keeping legacy PID decoding compatible.
- Added the runtime route from `LinuxContainer.processes()` through the runtime XPC service and client.
- Added the API-service route and `ContainerClient.processes(id:)` metadata mapping.
- Allowed process reads for running containers and rejected other lifecycle states.
- Updated `container top` to render standard process columns when metadata is present.
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

The resource test covers structured-data round trips and legacy payload decoding. The formatting tests cover the process table and the identifier compatibility fallback. Runtime behavior is exercised through the lower-runtime tests and the `container-compose top` integration path.

## Dependency Notes

This pull request must stack on the `apple/containerization` process-metadata primitive and on source-backed init-image installation when the runtime is built from a branch or local checkout. Do not submit the stephenlclarke dependency URL or fork revision in the Apple pull request.

## Remaining Risks

- PID membership and process metadata can change immediately after the snapshot is returned.
- CPU percentage is a point-in-time integer compatible with process-table presentation, not a long-running sampled metric.
- Upstream maintainers may prefer keeping the CLI table narrow and exposing only the typed API; the typed resource and route are the durable primitive for `container-compose`.
