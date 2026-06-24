# [Request]: Restart containers from stored restart policy after init exits

## Feature or enhancement request details

After `ContainerCreateOptions` can store a typed restart policy, `apple/container` needs API-server lifecycle behavior that actually applies the policy when the container init process exits. This is the runtime half of [apple/container#286](https://github.com/apple/container/issues/286), and it should reuse the direction from [apple/container#1258](https://github.com/apple/container/pull/1258) while keeping the implementation small enough to review independently.

Restart policies are runtime behavior, not Compose behavior. `container-compose` can normalize service `restart` values to typed `ContainerCreateOptions.restartPolicy`, but the decision to restart a stopped container must live in `apple/container` so direct API and CLI users get the same result.

Direction note: after JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), Docker/Compose restart value parsing belongs in `container-compose`. The Apple-facing slice is the stored policy plus scheduler behavior.

Requested behavior:

- Track per-container restart state inside `ContainersService`.
- Restart containers according to stored `ContainerCreateOptions.restartPolicy`.
- Support:
  - `no`: never restart automatically.
  - `on-failure`: restart only after a non-zero init exit.
  - `on-failure:<max-retries>`: stop after the configured retry count.
  - `on-failure:0`: treat as no retry cap, matching Docker/Moby semantics.
  - `always`: restart after zero or non-zero init exits unless the user stopped the container.
  - `unless-stopped`: same in-process restart behavior as `always`; future daemon-start behavior can distinguish it.
- Treat `container stop` and init-process `container kill` as manual stops that suppress automatic restart until the container is manually started again.
- Use Docker-style exponential backoff starting at 100ms and capped at 60s.
- Reset backoff after the restarted container remains running for 10 seconds.
- Cancel pending restart work when a container is stopped, killed, deleted, or cleaned up.
- Recheck cancellation and the restart task token before bootstrap so a manual lifecycle action during the restart window does not race with the scheduled restart.

Out of scope for this issue:

- Starting stored containers when the API server starts.
- Exposing restart count or last restart time in inspect/list output.
- Updating restart policies on an existing container.
- Compose-specific dependency or orchestration behavior.

References:

- [apple/container#286](https://github.com/apple/container/issues/286)
- [apple/container#1258](https://github.com/apple/container/pull/1258)
- [Docker restart policy documentation](https://docs.docker.com/engine/containers/start-containers-automatically/)
- [Docker `container run --restart` reference](https://docs.docker.com/reference/cli/docker/container/run/#restart-policies---restart)
- [Docker Compose service `restart` reference](https://docs.docker.com/reference/compose-file/services/#restart)

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
