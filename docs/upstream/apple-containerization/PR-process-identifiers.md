# Pull request: expose Linux container process metadata

<!-- markdownlint-disable MD013 -->

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change gives `LinuxContainer` callers a typed way to inspect the processes assigned to a running or paused container. The data belongs to the container's cgroup and `/proc` view inside the guest, so `vminitd` owns the read and validation path.

The API stays runtime-native. `containerization` returns process metadata rows and does not implement Docker command names, Compose service selection, or presentation.

Related issue draft:
[ISSUE-process-identifiers.md](ISSUE-process-identifiers.md).

## Commit Tracking

- `58c7eb72e1a6c1b17d8754c3593ebd0ad141193a` in
  `stephenlclarke/containerization` (`feat(runtime): expose container process
  metadata`).
- Guest build fix:
  `8cbc60df9047f308ba774ba5e18c1fb2746c06ef` in
  `stephenlclarke/containerization` (`fix(runtime): qualify process error
  existential`).
- Matched init-image build reference:
  `d8b9585a9855b1c0958d423a2d08b564eb6f8626` in
  `stephenlclarke/containerization` (`build(init): parameterize vminit image
  reference`).
- The dependent `apple/container` API/CLI slice is tracked in
  [PR-process-identifiers.md](../apple-container/PR-process-identifiers.md).
- Compose service selection and output are tracked in
  [PR-compose-top-process-list.md](../process-list/PR-compose-top-process-list.md).

Regenerate the checked-in sandbox gRPC sources from the updated proto after rebasing onto current `apple/containerization`.

## Implementation Details

- Added `ContainerProcessInfo` to the sandbox-agent protocol.
- Extended `ContainerProcessesResponse` with additive `processes` rows while preserving the existing `pids` field.
- Added `VirtualMachineAgent.containerProcessInfo(containerID:)` and the `Vminitd` client implementation.
- Added `LinuxContainer.processes()` for running and paused states.
- Read `cgroup.procs` through `Cgroup2Manager`, then collected UID, PID, PPID, CPU, start time, TTY, elapsed time, and command from guest `/proc`.
- Skipped exited processes whose `/proc/<pid>` entries disappear between cgroup membership and metadata reads.
- Qualified the missing-process helper with `Swift.Error` so the Linux `vminitd` build does not resolve the existential to `Cgroup2Manager.Error`.
- Added the server RPC mapping through `ManagedContainer`.
- Added the `VMINIT_IMAGE` Makefile parameter so stack automation can build the guest init image with the same reference configured in the isolated runtime.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter LinuxContainerTests/processInfoRowsAreReadFromTheAgent
make linux-test SWIFT_CONFIGURATION='--filter Cgroup2ManagerProcessTests'
CONTAINERIZATION_INIT_SOURCE_PATH=/Users/sclarke/github/containerization \
  CONTAINER_INIT_IMAGE_NAME=vminit:container-compose \
  APP_ROOT=/Users/sclarke/github/container-compose/.build/container-runtime \
  make -C /Users/sclarke/github/container init-block
make check
```

The Linux-container test covers the typed agent mapping. The focused Linux suite covers metadata parsing, command fallback, and exited-process skipping. The init-block command proves the Linux `vminitd` binary builds and loads into the matched runtime root.

## Compatibility Notes

- Existing callers are unchanged because the `pids` response field and `processIdentifiers()` API remain available.
- Stopped, created, and deleted containers continue to fail with an invalid state error.
- Docker and Docker Compose formatting are owned by `container-compose`, not by this API.

## Remaining Risks

- A process can exit between reading `cgroup.procs` and reading `/proc/<pid>`.
- CPU percentage is a point-in-time integer compatible with process-table presentation, not a long-running sampled metric.
- Generated gRPC sources may need mechanical conflict resolution after an upstream protocol change.
