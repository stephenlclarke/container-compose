# [Request]: Add typed container restart policy create options

## Feature or enhancement request details

`apple/container` needs a typed, persisted restart-policy surface before the runtime can implement automatic restarts and before `container-compose` can map Compose service restart policies without carrying Compose-specific behavior inside `apple/container`.

Docker exposes restart behavior at container creation time with `docker run --restart`. Docker Compose exposes the same local-development surface with service `restart`. The existing upstream feature request [apple/container#286](https://github.com/apple/container/issues/286) asks for `--restart` support, and [apple/container#1258](https://github.com/apple/container/pull/1258) prototypes a larger combined implementation. This smaller slice separates the public data shape from the restart scheduler so maintainers can review the API contract independently.

Direction note: after JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), `container-compose` should own Docker/Compose restart value parsing and precedence. The Apple-facing primitive is `ContainerCreateOptions.restartPolicy` plus runtime scheduling; any local `--restart` parser is a temporary validation bridge unless maintainers want it as an Apple-native resource-management convenience.

Requested behavior:

- Add a typed restart-policy model to `ContainerResource`.
- Store the policy in `ContainerCreateOptions` so it is available to the API service after creation.
- Decode older create-options JSON without a restart policy as the default `no` policy.
- Represent the Docker-compatible modes that Compose needs without requiring Compose policy in Apple:
  - `no`
  - `on-failure`
  - `on-failure:<max-retries>`
  - `always`
  - `unless-stopped`
- Reject retry counts on policies other than `on-failure`.
- Treat `on-failure:0` as no retry cap, matching Docker/Moby semantics and Colima's Docker-runtime behavior.
- Normalize direct API and decoded JSON policy shapes so retry counts only apply to `on-failure` and a `no` policy does not carry restart timing fields.
- Reject auto-remove combined with a restart policy, matching Docker's mutual exclusion between auto-remove and restart policy.

This issue is intentionally limited to the create-time policy surface. Runtime restart scheduling, backoff, restart counters, inspect/list presentation, and update-time policy changes should remain separate follow-up PRs.

References:

- [apple/container#286](https://github.com/apple/container/issues/286)
- [apple/container#1258](https://github.com/apple/container/pull/1258)
- [Docker restart policy documentation](https://docs.docker.com/engine/containers/start-containers-automatically/)
- [Docker `container run --restart` reference](https://docs.docker.com/reference/cli/docker/container/run/#restart-policies---restart)
- [Docker Compose service `restart` reference](https://docs.docker.com/reference/compose-file/services/#restart)

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
