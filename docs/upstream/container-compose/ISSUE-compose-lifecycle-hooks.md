# Complete Compose lifecycle hooks on macOS

## Compose Surface

Service lifecycle hooks and foreground one-off execution:

- `services.<name>.pre_start`
- `services.<name>.post_start`
- `services.<name>.pre_stop`
- `container compose up`, `start`, `restart`, and `run`

Each hook can provide `command`, `user`, `working_dir`, `privileged`, and
`environment`; `pre_start` can also select a helper `image`.

## Docker Compose V2 Behavior

Docker Compose V2 runs `pre_start` before starting a fully stopped service. It
creates one ephemeral helper at a time, inherits the target service container's
mounts and networks, overlays hook runtime options, waits for the helper, and
removes it. A failed helper gates service startup.

The hook is service-level rather than replica-level: it does not rerun for an
idempotent `up`, scaling while a replica remains active, or `restart`. It runs
again after the service is fully stopped and subsequently started. Docker
Compose V2 rejects `pre_start.per_replica: true`.

`post_start` runs after service startup. `pre_stop` runs before a
Compose-controlled stop, including a signal-driven foreground one-off. A
foreground `run` preserves detach keys, automatic removal, terminal output, and
the exact one-off process exit status.

Primary Docker Compose V2 references:

- [`pre_start.go` at v5.3.1](https://github.com/docker/compose/blob/v5.3.1/pkg/compose/pre_start.go)
- [`convergence.go` at v5.3.1](https://github.com/docker/compose/blob/v5.3.1/pkg/compose/convergence.go)
- [`run.go` at v5.3.1](https://github.com/docker/compose/blob/v5.3.1/pkg/compose/run.go)
- [Compose lifecycle hooks reference](https://docs.docker.com/compose/how-tos/lifecycle/)

## Previous container-compose Behavior

The normalized model already preserved lifecycle hooks. Detached service paths,
regular foreground `up`, and non-interactive foreground `run` supported
`post_start` and `pre_stop`, but:

- `pre_start` was rejected before resource creation;
- interactive foreground `run` did not use the supported fork's init-process
  reattach primitive;
- the supported-lane diagnostic incorrectly assigned those Compose
  orchestration gaps to missing Apple primitives;
- a one-off process failure could be rendered as a generic orchestration error
  instead of returning the process status directly.

## Likely Owner

`container-compose`.

The matched `stephenlclarke/container` runtime already provides the create,
volumes-from, network, log, wait, attach, signal, stop, and delete primitives
needed by this work. The implementation should remain in the Compose layer.
Stock `apple/container` still lacks the fork's interactive init-process stream
reattach primitive, so interactive lifecycle-managed `run` remains a
capability-negotiated compatibility boundary for stock Apple builds.

No `apple/container` or `containerization` source change or package-pin update
is required for the supported runtime lane.

## Minimal Example

```yaml
services:
  api:
    image: alpine:3.21
    command: ["sh", "-c", "sleep 300"]
    environment:
      BASE: service
    volumes:
      - /shared
    pre_start:
      - image: alpine:3.20
        command: ["sh", "-c", "printf 'prepared\n' >> /shared/hooks.log"]
        environment:
          BASE: hook
    post_start:
      - command: ["sh", "-c", "printf 'started\n' >> /shared/hooks.log"]
    pre_stop:
      - command: ["sh", "-c", "printf 'stopping\n' >> /shared/hooks.log"]
```

## Expected Behavior

- `pre_start` helpers run sequentially before a fully stopped service starts.
- Helpers inherit service environment, mounts, networks, platform, and hook
  overrides without adding Compose-specific behavior to the runtime fork.
- A non-zero helper status stops startup and the helper is removed.
- `pre_start` does not rerun during idempotent convergence, scaling, or
  `restart`; it reruns after a complete stop followed by `start`.
- `post_start` and `pre_stop` cover detached service, foreground service, and
  interactive/non-interactive one-off paths.
- Interactive one-offs retain signal proxy, detach keys, automatic removal,
  terminal output, and exact process status behavior.
- Helper images follow pull policy but remain absent from direct service-image
  projections, matching Docker Compose's visible `pull` and `config --images`
  behavior.

## Signed Handoff Commits

- Implementation and unit coverage:
  `ec3a0078a72611d1f7cf4717c28b8232d33e3a5e`
  (`feat(lifecycle): complete service and run hooks`).
- Docker Compose V2 parity fixture:
  `498a5381c7052c9e06f9887896b590a81c482c6e`
  (`test(lifecycle): add Compose v2 parity fixture`).

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked the current critical review and corrected its lifecycle
  ownership findings.
- [x] The implementation is macOS-feasible and contains no Windows-only work.
