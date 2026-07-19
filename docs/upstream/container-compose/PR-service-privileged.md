# Support Service-Level Privileged Containers

## Summary

This change wires service-level `privileged: true` through `container-compose`:

- Removes `privileged` from the unsupported device-access validator.
- Emits `--privileged` in command-vector service create/run paths.
- Sets `ProcessConfiguration.privileged` in the typed service create plan.
- Adds focused unit coverage, Docker Compose V2 config/dry-run parity, and a compose.yml-backed live runtime smoke test.

## Rationale

Docker Compose accepts `services.<name>.privileged: true` for service containers. Before this slice, `container-compose` rejected the field because released upstream `apple/container` did not expose a matching service create primitive.

The local `stephenlclarke/container` fork now exposes the generic process primitive through `container run --privileged`, `container create --privileged`, and `ProcessConfiguration.privileged`. With that runtime shape available, the Compose plugin can own the Docker Compose mapping while keeping broader runtime isolation behavior in the `container` fork.

References:

- Docker Compose service `privileged`: <https://docs.docker.com/reference/compose-file/services/#privileged>
- Apple/container upstream issue for `container run --privileged`: <https://github.com/apple/container/issues/206>
- Apple/container handoff draft: [PR-run-create-privileged.md](../apple-container/PR-run-create-privileged.md)

## Commit Tracking

- Required `container` fork commits: `9871093f3c5585775a7dc4ff957aa360baf47ac1` (`feat(process): support privileged init processes`) and `1a89a21abf78e84a8796a4325168ed6309a4e312` (`feat(runtime): restore privileged guest paths`).
- Container-compose integration commit: this local service-privileged slice.

## Implementation Details

- Removed service-level `privileged` from `unsupportedDeviceAccessFields(service:)`.
- Appended `--privileged` when rendering service create/run command vectors.
- Set `serviceCreateBaseProcess(service:).privileged` from `service.privileged == true`.
- Extended existing create, service-create-plan, and one-off run tests to assert the privileged mapping.
- Added a runtime dry-run smoke that reads a real compose.yml with `privileged: true` and checks the rendered `container run --privileged` command.
- Added a live Compose smoke that confirms a privileged service can write the guest hostname through `/proc/sys/kernel/hostname`, a generic Containerization path that is read-only by default.

## Docker Compose Parity

Docker Compose treats `privileged` as a service-level runtime field. The local parity behavior now accepts the same field and maps it to the closest available `container` fork primitive.

The generic runtime grants the init process all Linux capabilities and clears its default OCI masked/read-only guest paths. It does not claim Docker's full privileged-mode behavior for host devices, device cgroups, seccomp, AppArmor, or related host-isolation knobs. Service `devices` and the generic single Apple virtio GPU request path are handled by their dedicated runtime slices; vendor/native GPU passthrough and arbitrary host hardware remain separate runtime gaps.

The Docker Compose e2e fixture checkout was checked before adding the local parity smoke. The only matching fixture currently found was `pkg/e2e/fixtures/build-test/privileged/compose.yaml`, which exercises `build.privileged`, so this service-level slice uses a small local compose.yml fixture instead.

## Verification

Focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'serviceCreatePlanMapsCreateTimeRuntimePrimitives|upRejectsUnsupportedDeviceAccessFieldsBeforeCreatingResources|runRejectsUnsupportedDeviceAccessFieldsBeforeCreatingResources'
swift test --disable-automatic-resolution --filter createCreatesResourcesAndServiceContainersWithoutStartingThem
swift test --disable-automatic-resolution --filter runSupportsOneOffContainersAndOptionFlags
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 CONTAINER_COMPOSE_CONTAINER=/absolute/path/to/container/bin/container CONTAINER_BIN=/absolute/path/to/container/bin/container swift test --disable-automatic-resolution --filter runtimePrivilegedServiceRestoresGuestReadonlyPaths
CONTAINER_COMPOSE=/absolute/path/to/container-compose/.build/debug/compose DOCKER_COMPOSE=docker-compose ./Tools/parity/check-compose-privileged.sh --strict
```

Before release promotion, run the broader local gate:

```sh
make check
make coverage-check
markdownlint STATUS.md docs/upstream/apple-container/ISSUE-206.md docs/upstream/apple-container/PR-run-create-privileged.md docs/upstream/container-compose/ISSUE-compose-exec-privileged.md docs/upstream/container-compose/PR-compose-exec-privileged.md docs/upstream/container-compose/ISSUE-service-privileged.md docs/upstream/container-compose/PR-service-privileged.md
git diff --check
```

## Follow-Ups

- Keep device-oriented privileged-mode behavior tracked as separate runtime gaps until the `container` fork exposes security profile, arbitrary host-device, or vendor/native GPU primitives that match Docker's broader privileged behavior.
