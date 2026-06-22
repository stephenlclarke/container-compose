# Pull Request

## Summary

- Normalize Compose Deploy `restart_policy` as structured JSON from the compose-go helper.
- Map supported deploy restart policy conditions to fork-backed `apple/container` `--restart` create flags.
- Keep Docker Compose precedence by using deploy restart policy before service-level `restart`.
- Document `deploy.restart_policy.delay` and `deploy.restart_policy.window` as remaining apple/container runtime gaps.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

`deploy.restart_policy` is part of the Compose Deploy Specification and appears in real Compose files even when the workflow is local development. Docker Compose v2 gives deploy restart policy precedence over service-level `restart`, but this plugin previously rejected the whole field because the normalizer did not expose the structured policy to Swift.

The local `stephenlclarke/container` `logs-integration-chris` branch now carries restart create/runtime slices that reference [apple/container#286](https://github.com/apple/container/issues/286) and [apple/container#1258](https://github.com/apple/container/pull/1258):

- `feat(api): add restart policy create options` (`fcbccbb`), documented by `ISSUE-restart-policy-create-options.md` / `PR-restart-policy-create-options.md`.
- `feat(runtime): restart containers from policy` (`a20d6a3`), documented by `ISSUE-restart-policy-runtime.md` / `PR-restart-policy-runtime.md`.

With those fork primitives available, this plugin can map the subset of deploy restart policy that is expressible by the current runtime without adding Compose-specific code to `apple/container`.

## Implementation Details

- The Go normalizer adds `deployRestartPolicy` with `condition`, `delayNanoseconds`, `maxAttempts`, and `windowNanoseconds`.
- The normalizer stops reporting the whole `deploy.restart_policy` surface as an unsupported deploy field.
- `ComposeService` adds `ComposeDeployRestartPolicy`.
- `runtimeRestartPolicyArgument(service:)` now checks deploy restart policy before service-level `restart`.
- Supported mappings are:
  - `condition: none` -> `--restart no`
  - `condition: any` or an empty deploy policy -> `--restart always`
  - `condition: on-failure` -> `--restart on-failure`
  - `condition: on-failure` with `max_attempts` -> `--restart on-failure:<max-retries>`
- One-off `compose run` containers still do not receive `--restart`, even when the service has deploy restart policy.
- `delay` and `window` reject with precise apple/container runtime-gap messages.
- `max_attempts` with `condition: any` or `condition: none` rejects because the current fork-backed retry limit is only expressible for `on-failure`.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed branch: deploy restart `condition` values `none`, `any`, and `on-failure`, plus `max_attempts` with `on-failure`.
- Remaining gap: `deploy.restart_policy.delay` and `deploy.restart_policy.window` need additional `apple/container` restart timing primitives.
- Released-upstream caveat: this remains fork-backed until equivalent restart-policy create/runtime primitives are accepted in `apple/container`.
- Compose-specific model normalization, precedence, and one-off lifecycle behavior remain in this plugin.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
go test ./...
swift test --filter 'ComposeNormalizerTests/normalizesDeployRestartPolicyThroughComposeGo|ComposeOrchestratorTests/upMapsDeployRestartPolicyToContainerCreateFlags|ComposeOrchestratorTests/upRejectsDeployRestartDelayBeforeCreatingResources|ComposeOrchestratorTests/upRejectsDeployRestartMaxAttemptsWithoutOnFailure|ComposeOrchestratorTests/runDoesNotInheritDeployRestartPolicyForOneOffContainers'
```

Results: passed locally on 2026-06-22. The focused Swift run executed 5 selected tests.

Repository checks:

```sh
make swift-test
make check
markdownlint ISSUE-deploy-restart-policy.md PR-deploy-restart-policy.md
git diff --check
```

Results: all passed locally on 2026-06-22. `make swift-test` ran 532 Swift tests.

## container-compose Checks

- [x] I updated `COMPATIBILITY.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
