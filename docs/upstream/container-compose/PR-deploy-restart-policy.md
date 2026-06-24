# Pull Request

## Summary

- Normalize Compose Deploy `restart_policy` as structured JSON from the compose-go helper.
- Map supported deploy restart policy conditions to the plugin-owned restart-policy projection for non-job services.
- Keep Docker Compose precedence by using deploy restart policy before service-level `restart`.
- Map `deploy.restart_policy.delay` and `deploy.restart_policy.window` when the fork-backed timing primitive is present.
- Reject restart-capable deploy job policies until `apple/container` exposes a restart-aware wait primitive.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

`deploy.restart_policy` is part of the Compose Deploy Specification and appears in real Compose files even when the workflow is local development. Docker Compose v2 gives deploy restart policy precedence over service-level `restart`, but this plugin previously rejected the whole field because the normalizer did not expose the structured policy to Swift.

The local `stephenlclarke/container` fork now carries restart create/runtime slices that reference [apple/container#286](https://github.com/apple/container/issues/286) and [apple/container#1258](https://github.com/apple/container/pull/1258):

- Branch `restart-policy-create-options`, commit `c5668c19d139b1aeb7e2529cb1dedd01fb4532c1` (`feat(api): add restart policy create options`), documented by `docs/upstream/apple-container/ISSUE-restart-policy-create-options.md` / `docs/upstream/apple-container/PR-restart-policy-create-options.md`.
- Branch `restart-policy-runtime`, commit `b41bb830db708bc839c94e01c8a75c7fecbe3db0` (`feat(runtime): restart containers from policy`), documented by `docs/upstream/apple-container/ISSUE-restart-policy-runtime.md` / `docs/upstream/apple-container/PR-restart-policy-runtime.md`.

With those fork primitives available, this plugin can map the subset of deploy restart policy that is expressible by the current runtime without adding Compose-specific code to `apple/container`. The current live execution path still renders `--restart` through the command-vector bridge while typed service creation is being wired. Job-mode services are intentionally excluded for now because the current wait primitive observes one container exit and cannot yet wait through runtime restart attempts to the final job result.

The local `stephenlclarke/container` fork also now carries branch `restart-policy-timing`, commit `8b1eff72481fa497328414e0483a08c768826f1a` (`feat(runtime): add restart policy timing`), documented by `docs/upstream/apple-container/ISSUE-restart-policy-timing.md` / `docs/upstream/apple-container/PR-restart-policy-timing.md`, so the plugin can pass deploy restart `delay` and `window` to the fork-backed runtime.

## Commit Tracking

- Compose code commit: `06cc3220c03b8ce0ab2eaf83ed81c08aca7f74b4` on branch `stephenlclarke/container-compose` `compose-restart-policy-mapping`
- Container code commits: `c5668c19d139b1aeb7e2529cb1dedd01fb4532c1` (`feat(api): add restart policy create options`), `b41bb830db708bc839c94e01c8a75c7fecbe3db0` (`feat(runtime): restart containers from policy`), and `8b1eff72481fa497328414e0483a08c768826f1a` (`feat(runtime): add restart policy timing`) in `stephenlclarke/container`
- Lower runtime code commit: not required

## Implementation Details

- The Go normalizer adds `deployRestartPolicy` with `condition`, `delayNanoseconds`, `maxAttempts`, and `windowNanoseconds`.
- The normalizer stops reporting the whole `deploy.restart_policy` surface as an unsupported deploy field.
- `ComposeService` adds `ComposeDeployRestartPolicy`.
- The restart-policy projection now checks deploy restart policy before service-level `restart`.
- Supported mappings are:
  - `condition: none` -> `--restart no`
  - `condition: any` or an empty deploy policy -> `--restart always`
  - `condition: on-failure` -> `--restart on-failure`
  - `condition: on-failure` with `max_attempts` -> `--restart on-failure:<max-retries>`
  - `condition: on-failure` with `max_attempts: 0` -> `--restart on-failure`, following Docker/Moby's unlimited-retry convention.
- One-off `compose run` containers still do not receive `--restart`, even when the service has deploy restart policy.
- Deploy job services reject restart-capable deploy policies before resources are created until the runtime has a restart-aware job wait primitive; explicit `condition: none` remains allowed.
- `max_attempts` with `condition: any` or `condition: none` rejects because the current fork-backed retry limit is only expressible for `on-failure`.
- `delay` and `window` are projected to typed restart timing fields and currently passed as `--restart-delay` and `--restart-window` for service containers through the command-vector bridge.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed branch for non-job services: deploy restart `condition` values `none`, `any`, and `on-failure`, `max_attempts` with `on-failure`, and `delay` / `window` timing, currently through the command-vector bridge.
- Restart-capable deploy job policies remain rejected until `apple/container` can expose a wait result that accounts for runtime restart attempts instead of only the first observed exit.
- Remaining released-upstream gap: equivalent `apple/container` restart create/runtime/timing primitives must be accepted upstream.
- Released-upstream caveat: this remains fork-backed until equivalent restart-policy create/runtime primitives are accepted in `apple/container`.
- Compose-specific model normalization, precedence, and one-off lifecycle behavior remain in this plugin.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
go test ./...
swift test --filter 'ComposeNormalizerTests/normalizesDeployRestartPolicyThroughComposeGo|ComposeOrchestratorTests/upMapsDeployRestartPolicyToContainerCreateFlags|ComposeOrchestratorTests/upMapsDeployRestartTimingToContainerCreateFlags|ComposeOrchestratorTests/upMapsDeployRestartMaxAttemptsZeroToUnlimitedOnFailure|ComposeOrchestratorTests/upRejectsDeployRestartMaxAttemptsWithoutOnFailure|ComposeOrchestratorTests/upRejectsDeployJobRestartPolicy|ComposeOrchestratorTests/upAllowsDeployRestartPolicyNoneForDeployJobs|ComposeOrchestratorTests/runDoesNotInheritDeployRestartPolicyForOneOffContainers'
```

Results: passed locally on 2026-06-22. The latest focused timing run executed 4 selected orchestrator tests after the earlier normalizer/model run.

Repository checks:

```sh
make swift-test
make check
markdownlint docs/upstream/container-compose/ISSUE-deploy-restart-policy.md docs/upstream/container-compose/PR-deploy-restart-policy.md
git diff --check
```

Results: all passed locally on 2026-06-22. `make swift-test` ran 532 Swift tests.

Optional Docker Compose parity target, kept out of CI:

```sh
make docker-compose-restart-policy-parity
```

This validates Docker Compose V2 `HostConfig.RestartPolicy` behavior for service `restart`, deploy-over-service precedence, deploy `condition: any`, deploy `condition: none`, and `on-failure:0`.

## container-compose Checks

- [x] I updated `COMPATIBILITY.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
