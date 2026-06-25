# Pull Request

## Summary

- Map supported service-level Compose `restart` values to fork-backed `apple/container` `--restart` create flags.
- Keep one-off `container compose run` containers from inheriting service restart policies.
- Update compatibility and planning docs to separate service `restart` support from the remaining `deploy.restart_policy` model/runtime gap.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Service-level `restart` is part of common local-development Compose workflows. `container-compose` previously rejected all restart policies because upstream `apple/container` did not expose matching runtime primitives.

The current `stephenlclarke/container` `develop` fork integration lane carries two small, upstream-shaped runtime slices that reference [apple/container#286](https://github.com/apple/container/issues/286) and [apple/container#1258](https://github.com/apple/container/pull/1258):

- `feat(api): add restart policy create options` (`fcbccbb`), documented by `ISSUE-restart-policy-create-options.md` / `PR-restart-policy-create-options.md`.
- `feat(runtime): restart containers from policy` (`a20d6a3`), documented by `ISSUE-restart-policy-runtime.md` / `PR-restart-policy-runtime.md`.

With those fork primitives available, this plugin can map the Compose service-level policy without putting Compose-specific behavior into `apple/container`.

## Implementation Details

- `validateRuntimeSupport` now accepts supported service `restart` policies by sharing validation with the runtime argument builder.
- `runArguments` adds `--restart <policy>` for steady-state service containers.
- One-off `compose run` containers do not receive `--restart`, preserving one-off lifecycle behavior and avoiding `--rm` conflicts.
- Unsupported policy modes fail before creating resources with a precise error.
- `deploy.restart_policy` remains rejected because the normalizer currently reports it only through `unsupportedDeployFields`; a follow-up slice should expose structured `condition`, `delay`, `max_attempts`, and `window` fields.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed branch: `restart: no`, `restart: always`, `restart: unless-stopped`, `restart: on-failure`, and `restart: on-failure:<max-retries>`.
- Remaining gap: `deploy.restart_policy` needs a normalized model and may need additional runtime semantics for Docker Compose `delay` and `window`.
- Released-upstream caveat: this remains fork-backed until equivalent restart-policy create/runtime primitives are accepted in `apple/container`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'upMapsServiceRestartPoliciesToContainerCreateFlags|upRejectsInvalidRestartPoliciesBeforeCreatingResources|runDoesNotInheritServiceRestartPoliciesForOneOffContainers|runRejectsUnsupportedDeployFieldsBeforeCreatingResources'
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

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
