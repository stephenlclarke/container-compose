# Pull Request

## Summary

- Materialize Docker Compose runtime `configs.content`, `configs.environment`, and `secrets.environment` definitions into local project-scoped files.
- Mount generated config and secret files read-only through existing `apple/container` bind-mount arguments.
- Avoid writing secret material during dry-run and remove project-scoped materialized files during `down`.
- Update compatibility, planning, and handoff documentation.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose supports file-like runtime config and secret sources that can be represented locally without a first-class runtime store. Configs support `file`, `environment`, `content`, and `external`; secrets support `file` and `environment` for Docker Compose local workflows.

`apple/container` already exposes the runtime primitive needed for local file-like grants: read-only bind mounts. This plugin can therefore support inline config content and environment-backed config/secret values without adding Compose-specific policy to `apple/container`.

External configs/secrets and strict `uid`/`gid` ownership semantics remain separate runtime gaps because they need a lookup/store or ownership primitive rather than a simple local source file.

## Commit Tracking

- Compose code commit: `51be9a5` (`feat(configs): materialize compose config secrets`)
- Container code commit: not required; this slice only changes `container-compose`
- Lower runtime code commit: not required

## Implementation Details

- Added a configurable `ComposeExecutionOptions.materializedConfigSecretDirectory`, defaulting under the per-user `.container-compose` state directory.
- Resolved top-level config/secret definitions through one path that supports:
  - existing `file` sources as direct read-only bind mounts;
  - `configs.content` as generated config files with `0444` permissions;
  - `configs.environment` as generated config files with `0444` permissions;
  - `secrets.environment` as generated secret files with Compose default `0444` permissions.
- Included generated content in materialized file names so content changes affect the service config hash and trigger recreation. A follow-up slice also includes grant modes in the materialized file identity.
- Kept validation and dry-run paths side-effect free: dry-run renders the planned bind mount paths without writing local files.
- Removed project-scoped materialized files in `down` after containers are stopped and deleted.
- Kept content-backed secrets rejected because Docker Compose secrets document only `file` and `environment` sources.
- Added normalizer coverage for compose-go preserving inline and environment-backed config/secret definitions.

## Docker Compose Compatibility Notes

- Supported now: runtime service grants for file-backed configs/secrets, `configs.content`, `configs.environment`, and `secrets.environment`.
- Supported now: Docker Compose default mount targets, including `/<config-name>` for configs and `/run/secrets/<secret-name>` for secrets.
- Remaining gap: `external: true` configs/secrets still need an `apple/container` store or lookup primitive.
- Remaining gap: strict service-level `uid` and `gid` materialization needs runtime ownership support beyond bind-mounting a host file.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
go test ./...
swift test --filter 'ComposeOrchestratorTests/upMaterializesInlineConfigsAndEnvironmentBackedSecrets|ComposeOrchestratorTests/downRemovesMaterializedConfigAndSecretFiles|ComposeOrchestratorTests/upDryRunDoesNotMaterializeInlineConfigs|ComposeOrchestratorTests/runMaterializesEnvironmentBackedSecrets|ComposeOrchestratorTests/runRejectsUnsetEnvironmentBackedSecretsBeforeCreatingResources'
make check
make swift-test
make coverage-check
make cli-smoke-built
```

Results: passed locally on 2026-06-22. The focused Swift run executed 5 tests. The full Swift suite passed with 541 tests. `make coverage-check` reported Swift coverage at 89.71% and Go coverage at 93.37%. The Go normalizer run passed for `Tools/compose-normalizer`, and the built CLI smoke test passed.

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
