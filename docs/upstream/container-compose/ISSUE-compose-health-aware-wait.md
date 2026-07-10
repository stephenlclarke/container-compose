# Compose compatibility gap: health-aware lifecycle waits

## Compose Surface

Docker Compose treats a configured healthcheck as readiness state. `depends_on.condition: service_healthy` delays dependent startup, while `up --wait` and `start --wait` wait for configured services to become healthy and fail when a service becomes unhealthy.

## Required Runtime Boundary

The Compose plugin should own dependency and timeout policy. The container runtime should provide generic primitives only:

- typed healthcheck configuration;
- Docker-compatible probe cadence and retry state;
- current `starting`, `healthy`, or `unhealthy` state;
- health transition events; and
- health in structured container discovery output.

The runtime work is a focused implementation of [apple/container#1918](https://github.com/apple/container/issues/1918). Compose-specific waits remain in this repository.

## Acceptance Criteria

- `condition: service_healthy` starts dependents only after every dependency replica is healthy.
- `up --wait` and `start --wait` wait for health when a service has a healthcheck and for running state otherwise.
- `--wait-timeout` applies to the complete selected service set.
- An unhealthy service fails with a deterministic service/container diagnostic.
- `ps --format json` includes current health.
- A live parity fixture exercises healthy `up`, healthy `start`, and unhealthy failure against Docker Compose v2.

## Toolchain Constraint

Swift 6.3 can corrupt task-stack allocation when a large async return is followed by another suspension. The observed `freed pointer was not the last allocation` failure matches [swiftlang/swift#81771](https://github.com/swiftlang/swift/issues/81771). Live polling keeps the large discovery result in a non-inlined child frame and uses a short cancellation-aware blocking delay for the production default; tests retain an injected async sleeper.

## References

- Docker Compose `up`: [CLI reference](https://docs.docker.com/reference/cli/docker/compose/up/)
- Docker Compose `start`: [CLI reference](https://docs.docker.com/reference/cli/docker/compose/start/)
- Compose `depends_on`: [services reference](https://docs.docker.com/reference/compose-file/services/#depends_on)
- Runtime health issue: [apple/container#1918](https://github.com/apple/container/issues/1918)
- Swift task-stack issue: [swiftlang/swift#81771](https://github.com/swiftlang/swift/issues/81771)

## Project Checks

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md` and the current CLI support matrix.
- [x] Runtime changes remain generic and Apple-shaped.
