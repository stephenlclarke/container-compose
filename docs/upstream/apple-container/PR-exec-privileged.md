# Pull Request

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change adds a narrow privileged-process exec primitive to the local `container` integration branch.

Higher-level orchestration sometimes needs to start an additional process with elevated Linux capabilities inside an already-running container. Today the local Compose plugin must reject `exec --privileged`, lifecycle hook `privileged: true`, and `develop.watch sync+exec` `privileged: true` because the process configuration sent to `apple/container` has no field for that intent.

The Apple-facing shape stays generic: `ProcessConfiguration` carries process privilege intent, the CLI exposes it for `container exec`, and the Linux runtime server maps privileged exec to all Linux capabilities. Compose service selection, hook behavior, dry-run formatting, and Docker Compose support status remain in `container-compose`.

References:

- Docker Compose exec reference: <https://docs.docker.com/reference/cli/docker/compose/exec/>
- Docker container exec reference: <https://docs.docker.com/reference/cli/docker/container/exec/>

## Commit Tracking

- Container code commit: `39a2ce4ccb6c474d41a6146a6148d445b7fa0554` in `stephenlclarke/container` (`feat(exec): support privileged processes`).
- Compose integration code is tracked in `docs/upstream/container-compose/PR-compose-exec-privileged.md`, not part of this Apple PR.

## Implementation Details

- Added `ProcessConfiguration.privileged` with a default initializer value of `false`.
- Added explicit `Codable` handling so older serialized process configurations decode with `privileged == false`.
- Added `container exec --privileged`.
- Passed the CLI flag into `ProcessConfiguration`.
- Split exec capability selection so ordinary exec still honors container `capAdd` and `capDrop`, while privileged exec uses `LinuxCapabilities.allCapabilities`.
- Added focused parser, coding, and runtime capability tests.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --disable-automatic-resolution --filter 'ProcessConfigurationPrivilegeTests|RuntimeServiceHostsTests|ContainerExecCommandTests'
make check
git diff --check
```

## Dependency Notes

This slice does not require a new `containerization` API because `Containerization.LinuxCapabilities.allCapabilities` already exists.

## Remaining Risks

- This maps privileged exec to all Linux capabilities. It does not change mounts, devices, seccomp, sandboxing, or other container-create-time isolation choices.
- A future upstream review may prefer a narrower process capability override instead of a Docker-shaped `--privileged` CLI spelling; the typed `ProcessConfiguration.privileged` field is the durable runtime boundary for this slice.
