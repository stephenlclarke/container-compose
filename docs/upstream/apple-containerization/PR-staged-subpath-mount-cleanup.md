# Pull Request: release staged volume-subpath mounts during container teardown

## Summary

- Preserve staged subpath mount metadata from creation through running and
  paused container state.
- Unmount each staged bind after rootfs teardown and before its backing volume.
- Add focused regression coverage for the complete guest cleanup order.

## Intended Review Delta

Apply the signed commit
`93d77103c9a1ada25fd825478b2643e296810dc2`
(`fix(mounts): release staged subpath mounts`) from
`stephenlclarke/containerization`.

The correction is confined to the generic `LinuxContainer` lifecycle. It adds
no Docker or Compose parser, retry loop, runtime API, Windows behavior, or
macOS-specific policy. The companion report is
[ISSUE-staged-subpath-mount-cleanup.md](ISSUE-staged-subpath-mount-cleanup.md).

## Code Map

- `Sources/Containerization/LinuxContainer.swift`: carries the staged mount
  map into running/paused state and removes the staged bind plus backing volume
  in reverse attachment order during `stop()`.
- `Tests/ContainerizationTests/LinuxContainerTests.swift`: records guest
  unmount requests and verifies rootfs → staged subpath → backing volume.

## Validation

```console
swift test --filter blockMountSubpathStagesASecureBindMount
make coverage
make check
CONTAINER_STACK_REPO=/absolute/path/to/container make docker-compose-image-volumes-parity
```

The focused unit test, full coverage suite, and formatter/license checks pass
locally. The downstream Compose parity fixture is the macOS integration proof
because it starts the actual subpath service then removes its project.

## Compatibility and Risks

- Normal block-volume mounts remain unchanged because no staged subpath entry
  exists for them.
- Multiple staged entries are torn down in reverse attachment order, preserving
  bind-before-backing-volume dependency order.
- The change is safe for generic Linux guests and required by macOS-hosted
  Containerization; it neither advertises nor requires Windows support.

## Handoff Status

No Apple remote has been pushed. The Compose stack pin must include this
revision for release and source-matched parity validation.
