# [Request]: Add restart policy timing controls

## Problem

`apple/container` can now store and apply Docker-style restart policy mode and
retry count on the local fork, but the runtime policy still uses fixed internal
timing constants:

- restart attempts use the built-in exponential backoff starting at 100 ms
- retry state resets only after the built-in 10 second stable-run window

Docker Compose Deploy `restart_policy` also exposes timing fields:

```yaml
services:
  worker:
    image: example/worker
    deploy:
      restart_policy:
        condition: on-failure
        delay: 5s
        window: 30s
```

Without runtime timing fields, external clients such as `container-compose` have
to reject `deploy.restart_policy.delay` and `deploy.restart_policy.window`,
even when the restart mode and retry count are otherwise supported.

## Proposed Scope

- Add optional restart timing fields to `ContainerRestartPolicy`.
- Preserve the existing default behavior when those fields are absent.
- Use `retryDelayInNanoseconds` as a fixed delay between attempts when it is
  configured.
- Use `successfulRunDurationInNanoseconds` as the stable-run window before
  retry state resets when it is configured.
- Accept typed timing values through `ContainerRestartPolicy` so local
  integration can exercise the runtime model without relying on Compose-owned
  duration parsing.
- Keep Compose-specific field names, service selection, and deploy precedence
  in `container-compose`.

Direction note: after JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), Docker/Compose duration strings for deploy restart policy belong in `container-compose`. The Apple-facing ask is typed retry delay and successful-run window fields plus runtime behavior.

## Out Of Scope

- No Compose-specific code in `apple/container`.
- No scheduler or Swarm service model.
- No `container update --restart` equivalent.
- No API-server startup auto-start behavior for stopped containers with
  `always` or `unless-stopped`.

## References

- Docker Compose Deploy restart policy: <https://docs.docker.com/reference/compose-file/deploy/#restart_policy>
- Docker restart policy behavior: <https://docs.docker.com/engine/containers/start-containers-automatically/>
- Related apple/container issue: <https://github.com/apple/container/issues/286>
- Related apple/container PR reference: <https://github.com/apple/container/pull/1258>
- Prior fork handoff: `docs/upstream/apple-container/ISSUE-restart-policy-create-options.md`
- Prior fork handoff: `docs/upstream/apple-container/ISSUE-restart-policy-runtime.md`

## Code Of Conduct

- [x] I agree to follow this project's Code of Conduct.
