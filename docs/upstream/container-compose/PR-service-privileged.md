# Support Service-Level Privileged Containers

## Summary

This change wires service-level `privileged: true` through `container-compose`:

- Removes `privileged` from the unsupported device-access validator.
- Emits `--privileged` in command-vector service create/run paths.
- Sets `ProcessConfiguration.privileged` in the typed service create plan.
- Adds focused unit coverage and a compose.yml-backed runtime dry-run smoke test.

## Rationale

Docker Compose accepts `services.<name>.privileged: true` for service containers. Before this slice, `container-compose` rejected the field because released upstream `apple/container` did not expose a matching service create primitive.

The local `stephenlclarke/container` fork now exposes the generic process primitive through `container run --privileged`, `container create --privileged`, and `ProcessConfiguration.privileged`. With that runtime shape available, the Compose plugin can own the Docker Compose mapping while keeping broader runtime isolation behavior in the `container` fork.

References:

- Docker Compose service `privileged`: <https://docs.docker.com/reference/compose-file/services/#privileged>
- Apple/container upstream issue for `container run --privileged`: <https://github.com/apple/container/issues/206>
- Apple/container handoff draft: [PR-run-create-privileged.md](../apple-container/PR-run-create-privileged.md)

## Commit Tracking

- Required `container` fork commit: `9871093f3c5585775a7dc4ff957aa360baf47ac1` (`feat(process): support privileged init processes`).
- Container-compose integration commit: this local service-privileged slice.

## Implementation Details

- Removed service-level `privileged` from `unsupportedDeviceAccessFields(service:)`.
- Appended `--privileged` when rendering service create/run command vectors.
- Set `serviceCreateBaseProcess(service:).privileged` from `service.privileged == true`.
- Extended existing create, service-create-plan, and one-off run tests to assert the privileged mapping.
- Added a runtime dry-run smoke that reads a real compose.yml with `privileged: true` and checks the rendered `container run --privileged` command.

## Docker Compose Parity

Docker Compose treats `privileged` as a service-level runtime field. The local parity behavior now accepts the same field and maps it to the closest available `container` fork primitive.

Known difference: this implementation grants the init process the runtime's extended Linux capability set. It does not claim Docker's full privileged-mode behavior for host devices, seccomp, AppArmor, or related isolation knobs. Compose fields that require those missing primitives, including `devices` and `gpus`, remain explicitly blocked and documented as separate runtime gaps.

The Docker Compose e2e fixture checkout was checked before adding the local parity smoke. The only matching fixture currently found was `pkg/e2e/fixtures/build-test/privileged/compose.yaml`, which exercises `build.privileged`, so this service-level slice uses a small local compose.yml fixture instead.

## Verification

Focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'serviceCreatePlanMapsCreateTimeRuntimePrimitives|upRejectsUnsupportedDeviceAccessFieldsBeforeCreatingResources|runRejectsUnsupportedDeviceAccessFieldsBeforeCreatingResources'
swift test --disable-automatic-resolution --filter createCreatesResourcesAndServiceContainersWithoutStartingThem
swift test --disable-automatic-resolution --filter runSupportsOneOffContainersAndOptionFlags
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeDryRunUpRendersServicePrivilegedCommand
```

Before release promotion, run the broader local gate:

```sh
make check
make coverage-check
markdownlint STATUS.md docs/upstream/apple-container/ISSUE-206.md docs/upstream/apple-container/PR-run-create-privileged.md docs/upstream/container-compose/ISSUE-compose-exec-privileged.md docs/upstream/container-compose/PR-compose-exec-privileged.md docs/upstream/container-compose/ISSUE-service-privileged.md docs/upstream/container-compose/PR-service-privileged.md
git diff --check
```

## Follow-Ups

- Keep device-oriented privileged-mode behavior tracked as separate runtime gaps until the `container` fork exposes device, security profile, or GPU primitives that match Docker's broader privileged behavior.
