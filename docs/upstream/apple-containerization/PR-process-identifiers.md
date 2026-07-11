# Pull request: expose Linux container process identifiers

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change gives `LinuxContainer` callers a typed way to inspect the process
identifiers assigned to a running or paused container. The data already belongs
to the container's cgroup inside the guest, so `vminitd` is the correct owner of
the read and validation path.

The API stays runtime-native: `containerization` returns `[Int32]` and does not
implement Docker command names, Compose service selection, or presentation.

Related issue draft:
[ISSUE-process-identifiers.md](ISSUE-process-identifiers.md).

## Commit Tracking

- `d69f7e51c5ae9ecec6ad7fc4a6358b824cc515e7` in
  `stephenlclarke/containerization` (`feat(runtime): expose container process
  identifiers`).
- `aaa143b15f426912342cb4f29dc6a55065ba0651` in
  `stephenlclarke/containerization` (`fix(runtime): allow paused process
  listing`).
- `c7247cba24e5f6c8e3489d23b352d89eec410918` in
  `stephenlclarke/containerization` (`test(runtime): cover cgroup process
  identifier parsing`).
- The dependent `apple/container` API/CLI slice is tracked in
  [PR-process-identifiers.md](../apple-container/PR-process-identifiers.md).
- Compose service selection and output remain in
  [PR-compose-top-process-list.md](../process-list/PR-compose-top-process-list.md).

Squash the three lower-runtime commits when preparing the Apple pull request.
Regenerate the checked-in sandbox gRPC sources from the updated proto after
rebasing onto current `apple/containerization`.

## Implementation Details

- Added `ContainerProcesses` request and response messages to the sandbox-agent
  protocol.
- Added `VirtualMachineAgent.containerProcesses(containerID:)` and the
  `Vminitd` client implementation.
- Added `LinuxContainer.processIdentifiers()` for running and paused states.
- Read `cgroup.procs` through `Cgroup2Manager`, rejecting malformed identifiers
  and sorting valid PIDs deterministically.
- Added the server RPC and managed-container bridge.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter LinuxContainerTests/processIdentifiersAreReadFromTheAgent
make linux-test SWIFT_CONFIGURATION='--filter Cgroup2ManagerProcessTests'
make check
```

The Linux-container test covers running and paused state access. The focused
Linux suite covers malformed, empty, and sorted `cgroup.procs` values.

## Compatibility Notes

- Existing callers are unchanged because the new protocol requirement has a
  default unsupported implementation.
- Stopped, created, and deleted containers continue to fail with an invalid
  state error.
- The API intentionally exposes process identifiers only. Rich process metadata
  is a separate runtime capability.

## Remaining Risks

- The process can exit between reading `cgroup.procs` and a caller using the
  returned identifier.
- Generated gRPC sources may need mechanical conflict resolution after an
  upstream protocol change.
