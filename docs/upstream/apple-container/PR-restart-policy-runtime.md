# feat(runtime): restart containers from stored policy

## Commit Tracking

- Commit: `b41bb830db708bc839c94e01c8a75c7fecbe3db0`
- Stacks on commit `c5668c19d139b1aeb7e2529cb1dedd01fb4532c1` in `stephenlclarke/container`.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This is the second small restart-policy slice for [apple/container#286](https://github.com/apple/container/issues/286). It builds on the typed create-options surface from `docs/upstream/apple-container/ISSUE-restart-policy-create-options.md` / `docs/upstream/apple-container/PR-restart-policy-create-options.md` and uses [apple/container#1258](https://github.com/apple/container/pull/1258) as the implementation reference.

The goal is to keep restart behavior generic to `apple/container`: direct API callers, any native Apple command surface, and `container-compose` should all rely on the same runtime lifecycle behavior instead of carrying separate restart loops in clients. Following JLogan's guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), Docker/Compose restart parsing stays in `container-compose`; this Apple PR should be framed as scheduler behavior for stored typed policies.

## Implementation Details

- Adds `ContainerRestartTracker`, a pure helper that owns Docker-style restart decisions and backoff progression.
- Tracks one restart helper per `ContainersService.ContainerState`.
- Schedules an automatic restart when a container exits and its stored policy allows restart.
- Applies the documented Docker policy behavior:
  - `no` does not restart.
  - `on-failure` restarts only for non-zero exits.
  - `on-failure:<max-retries>` stops after the configured retry count.
  - `on-failure:0` is normalized to no retry cap, matching Docker/Moby semantics.
  - `always` and `unless-stopped` restart zero and non-zero exits unless the user manually stopped the container.
- Treats `container stop` and init-process `container kill` as manual stops.
- Cancels pending restart and stability tasks when a user stops, kills, or deletes the container.
- Rechecks cancellation and the restart task token after preparing the stopped container and before bootstrapping it, so a manual lifecycle action during the restart window wins over the scheduled restart.
- Uses exponential backoff from 100ms to 60s.
- Resets backoff after a container remains running for 10 seconds.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Local validation:

```sh
/usr/bin/swift test --filter 'ContainerRestartTrackerTests|ParserTest|ContainerCreateOptionsTests'
```

Focused test evidence:

- `ContainerRestartTrackerTests` covers `no`, `on-failure`, max retries, `on-failure:0` as unlimited, `always`, manual stop suppression, and stable-run backoff reset.
- Existing create-option tests continue to cover the persisted option surface. Parser tests in the local fork cover only the temporary command-vector bridge.

## Compatibility Notes

This change does not affect containers with the default `no` restart policy. Non-default restart policies are additive behavior for containers explicitly created with a restart policy.

`unless-stopped` intentionally matches `always` for in-process restarts in this slice. Docker distinguishes those policies when the daemon starts after a manual stop; API-server startup behavior should be reviewed separately.

## Docker Parity Notes

Docker documents a restart backoff that doubles from 100ms up to one minute and resets after the container runs successfully for at least 10 seconds. This slice mirrors those timing rules. Docker also suppresses restart after a manual stop until the container is manually started again; this slice applies that behavior to `container stop` and init-process `container kill`. Moby treats `MaximumRetryCount == 0` as unlimited, and Colima's Docker runtime delegates restart behavior to Docker Engine, so `on-failure:0` is preserved as unlimited rather than zero retries.

## Remaining Risks

- API-server startup auto-start behavior is still missing.
- Restart count, active restarting status, and last restart timestamps are not exposed yet.
- There is no `container update --restart` equivalent yet.
- No slow CLI integration test is added in this slice; the scheduler policy is covered with pure unit tests, and runtime end-to-end coverage should be added once the API shape is accepted.
