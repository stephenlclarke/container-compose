# Pull Request

## Summary

- Map supported service-level Compose `restart` values to the plugin-owned restart-policy projection.
- Keep one-off `container compose run` containers from inheriting service restart policies.
- Reject restart-capable service-level restart policies for deploy job modes until `apple/container` exposes a restart-aware wait primitive.
- Update compatibility and planning docs to separate service `restart` support from the follow-up `deploy.restart_policy` slice.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Service-level `restart` is part of common local-development Compose workflows. `container-compose` previously rejected all restart policies because upstream `apple/container` did not expose matching runtime primitives.

The local `stephenlclarke/container` fork now carries two small, upstream-shaped runtime slices that reference [apple/container#286](https://github.com/apple/container/issues/286) and [apple/container#1258](https://github.com/apple/container/pull/1258):

- Branch `restart-policy-create-options`, commit `c5668c19d139b1aeb7e2529cb1dedd01fb4532c1` (`feat(api): add restart policy create options`), documented by `docs/upstream/apple-container/ISSUE-restart-policy-create-options.md` / `docs/upstream/apple-container/PR-restart-policy-create-options.md`.
- Branch `restart-policy-runtime`, commit `b41bb830db708bc839c94e01c8a75c7fecbe3db0` (`feat(runtime): restart containers from policy`), documented by `docs/upstream/apple-container/ISSUE-restart-policy-runtime.md` / `docs/upstream/apple-container/PR-restart-policy-runtime.md`.

With those fork primitives available, this plugin can map the Compose service-level policy without putting Compose-specific behavior into `apple/container`. The current live execution path still renders `--restart` through the command-vector bridge while typed service creation is being wired.

## Commit Tracking

- Compose code commit: `06cc3220c03b8ce0ab2eaf83ed81c08aca7f74b4` on branch `stephenlclarke/container-compose` `compose-restart-policy-mapping`
- Container code commits: `c5668c19d139b1aeb7e2529cb1dedd01fb4532c1` (`feat(api): add restart policy create options`) and `b41bb830db708bc839c94e01c8a75c7fecbe3db0` (`feat(runtime): restart containers from policy`) in `stephenlclarke/container`
- Lower runtime code commit: not required

## Implementation Details

- `validateRuntimeSupport` now accepts supported service `restart` policies by sharing validation with the runtime argument builder.
- The service create path builds a deterministic restart-policy projection.
- `runArguments` adds `--restart <policy>` for steady-state service containers in the current command-vector bridge.
- One-off `compose run` containers do not receive `--restart`, preserving one-off lifecycle behavior and avoiding `--rm` conflicts.
- `deploy.mode: replicated-job` and `deploy.mode: global-job` services reject restart-capable service policies until the runtime can wait through restart attempts to the final job result; explicit `restart: no` remains allowed.
- Unsupported policy modes fail before creating resources with a precise error.
- `deploy.restart_policy` is intentionally left to the follow-up deploy restart-policy slice, which exposes structured `condition`, `delay`, `max_attempts`, and `window` fields.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed branch for non-job services: `restart: no`, `restart: always`, `restart: unless-stopped`, `restart: on-failure`, and `restart: on-failure:<max-retries>`, currently through the command-vector bridge.
- Restart-capable deploy job policies remain rejected pending a restart-aware `apple/container` wait primitive.
- Follow-up coverage: `deploy.restart_policy` is handled by `docs/upstream/container-compose/ISSUE-deploy-restart-policy.md` / `docs/upstream/container-compose/PR-deploy-restart-policy.md`.
- Released-upstream caveat: this remains fork-backed until equivalent restart-policy create/runtime primitives are accepted in `apple/container`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'upMapsServiceRestartPoliciesToContainerCreateFlags|upRejectsServiceRestartPoliciesForDeployJobs|upRejectsOnFailureServiceRestartPoliciesForDeployJobs|upAllowsServiceRestartNoneForDeployJobs|upRejectsInvalidRestartPoliciesBeforeCreatingResources|runDoesNotInheritServiceRestartPoliciesForOneOffContainers|runRejectsUnsupportedDeployFieldsBeforeCreatingResources'
```

Result: passed locally on 2026-06-22.

Repository checks:

```sh
make swift-test
make check
markdownlint docs/upstream/container-compose/ISSUE-service-restart-policy.md docs/upstream/container-compose/PR-service-restart-policy.md
git diff --check
```

Results: all passed locally on 2026-06-22. `make swift-test` ran 528 Swift tests.

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
