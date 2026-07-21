# Isolate deterministic anonymous volume identities

## Summary

- Scope deterministic anonymous runtime volume names to the service and replica instead of the mount target alone.
- Scope one-off runtime volume names to the service and exact one-off container identity.
- Keep renewal, selected cleanup, volume reporting, and labels aligned with the new managed service names.
- Extend the local Docker Compose V2 fixture to compare distinct anonymous volumes for two services and a one-off run.

## Type of Change

- [x] Bug fix
- [x] Test and Docker Compose V2 parity coverage
- [x] Documentation update
- [ ] Apple Container API change
- [ ] Apple Containerization API change

## Apple-Shaped Boundary

This is a Compose-only policy change. It consumes the existing Apple `container volume create`, mount, list, and delete primitives without adding Docker-specific state or APIs to either Apple fork. The existing deterministic naming and cleanup model remains intact; only the missing container identity component is added.

## Implementation Details

- `MountRenderContext` carries the exact runtime container name and whether it is one-off.
- Managed services use `project_anon-<service>-<replica>-<target-hash>`.
- One-off runs use `project_anon-<service>-run-<container-and-target-hash>`.
- Cleanup and volume reporting enumerate the same service/replica names as creation and mount rendering.
- `Tools/parity/check-compose-volume-labels.sh` now uses a Docker Compose YAML fixture with two same-target services and one one-off run, then verifies that all three mounted volume names are distinct. The container-compose half checks its corresponding dry-run command stream.

## Validation

```sh
swift test --filter 'ComposeCoreTests.ComposeOrchestratorTests/(upMapsAnonymousVolumesPerServiceReplica|upIsolatesAnonymousVolumesForSingleReplicaServices|runIsolatesAnonymousVolumeFromManagedService|downServiceSelectionPreservesSharedProjectResources)'
bash -n Tools/parity/check-compose-volume-labels.sh
shellcheck Tools/parity/check-compose-volume-labels.sh
./Tools/parity/check-compose-volume-labels.sh --strict
make check
make coverage-check
git diff --check
```

## Compatibility

Existing managed service anonymous volumes become service-scoped on their next recreation. This deliberately stops the prior accidental sharing between separate single-replica services. Named volumes and explicit external volume names are unchanged.

## Remaining Risks

- Docker Compose uses randomly generated anonymous volume names, whereas container-compose retains deterministic names so `down --volumes` and `--renew-anon-volumes` can resolve Apple runtime resources. The Docker Compose V2 parity check asserts the shared semantic: separate container identities do not share a volume.
- At the time of this historical anonymous-identity slice, Docker copy-up, complete `volume.nocopy`, and image-declared anonymous volumes were still pending. The implemented image-volume lifecycle policy is now documented in [PR-image-volume-copy-up-lifecycle.md](PR-image-volume-copy-up-lifecycle.md); non-local volume plugins, recursive bind modes, and consistency/cache modes remain limitations tracked in `STATUS.md`.

## Commit Tracking

- `fix(volumes): isolate anonymous mount identities` (signed implementation commit for this slice).
