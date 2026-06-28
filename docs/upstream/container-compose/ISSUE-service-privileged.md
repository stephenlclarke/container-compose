# Support Service-Level Privileged Containers

## Summary

`container compose` should accept `services.<name>.privileged: true` and map it to the matching local `container` runtime primitive instead of rejecting the service before resources are created.

Docker Compose documents `privileged` as a service field, and Compose files can use it for workloads that need elevated Linux capabilities. The local `stephenlclarke/container` fork now exposes `--privileged` on the process creation path used by `container run` and `container create`, so `container-compose` can pass the service intent through for both steady-state service containers and one-off `compose run` containers.

## Acceptance Criteria

- `privileged: true` is no longer rejected by the unsupported device-access validator.
- `compose create` emits `container create --privileged` for affected services.
- `compose up` and service start planning set `ProcessConfiguration.privileged` for the init process.
- `compose run` inherits service-level `privileged: true` and emits `container run --privileged`.
- Unsupported device access fields such as `devices`, `device_cgroup_rules`, and `gpus` remain rejected before resource creation.
- Runtime dry-run smoke covers a compose.yml with service-level `privileged: true`.

## Parity Notes

Docker Compose reference: <https://docs.docker.com/reference/compose-file/services/#privileged>

The Docker Compose e2e fixture checkout was checked for an existing reusable example. It contains `pkg/e2e/fixtures/build-test/privileged/compose.yaml`, but that fixture covers build-time `build.privileged: true`, not service-level runtime `privileged: true`. This slice therefore uses a minimal service-level fixture in the local runtime dry-run smoke.

## Notes

The current runtime mapping grants the service init process the runtime's extended Linux capability set. It does not implement Docker's full privileged behavior for devices, seccomp, AppArmor, or other isolation boundaries. Device-oriented fields remain separate runtime gaps.
