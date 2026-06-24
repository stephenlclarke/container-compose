# Pull Request

## Summary

- Preserve compose-go normalized `deploy.mode` values in the Swift project model.
- Support Docker Compose local `replicated-job` and `global-job` behavior on the fork-backed branch by starting job replicas detached and waiting each replica to exit successfully.
- Reject restart-capable job policies until the runtime can report final job results after restart attempts.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose accepts Compose Deploy job modes for completion-oriented local workflows such as schema migrations and one-shot setup tasks. The Compose Deploy Specification documents that job modes are expected to exit with status `0`, and that completed tasks remain until explicitly removed.

`container-compose` already had most of the local primitives needed for this once the fork-backed runtime exposed stopped-container exit metadata. It could create scaled replicas, wait running containers, and replay stored exit metadata through the lifecycle adapter. The missing piece was preserving the deploy mode and applying completion semantics after each job service starts.

References:

- Compose Deploy `mode`: <https://docs.docker.com/reference/compose-file/deploy/#mode>
- Docker service job behavior: <https://docs.docker.com/reference/cli/docker/service/create/#running-as-a-job>
- Related stopped-container exit metadata: [apple/container#1562](https://github.com/apple/container/pull/1562)

## Commit Tracking

- Compose code commit: `be898ee` (`feat(deploy): support compose job modes`)
- Container code dependency: `9b6f743` in `stephenlclarke/container` (`feat(api): expose container exit metadata`)
- Lower runtime code commit: not required

## Implementation Details

- Added `deployMode` to the Go normalizer output and Swift `ComposeService` model.
- Changed deploy-mode normalization so `replicated-job` and `global-job` are local supported deploy modes rather than unsupported deploy fields.
- Updated `up` reconciliation to record deterministic job replica targets while each service is reconciled.
- Forced job service containers to start detached so the plugin can own the completion wait.
- Added `waitForDeployJobService(service:targets:)` to wait each job replica and fail on non-zero exit before later services start.
- Rejected restart-capable service-level and deploy-level restart policies on job services before runtime side effects because the current wait primitive observes one exit and cannot yet report the final job result after runtime restart attempts. Explicit no-restart policies remain allowed.
- Updated `DOCKER-COMPOSE-PARITY.md`, `PLAN.md`, and `STATUS.md`.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed integration branch: `deploy.mode: replicated-job`.
- Supported now on the fork-backed integration branch: `deploy.mode: global-job` as the local single-host equivalent.
- Supported now: deploy `replicas` / service `scale` fan-out for job services.
- Supported now: non-zero job exits fail `up` before later services start.
- Remaining Compose/runtime gap: restart-capable job policies need a restart-aware `apple/container` wait primitive before they can be enabled.
- Remaining upstream gap: released apple/container still needs accepted stopped-container exit metadata before this can work without the fork.
- Remaining Compose gap: external config/secret stores are still blocked separately.
- Non-goal: Swarm scheduler placement, multi-node global behavior, and CLI-only job concurrency controls.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
go test ./...
swift test --filter 'ComposeNormalizerTests/normalizesDeployJobModesThroughComposeGo|ComposeOrchestratorTests/upWaitsForDeployJobModeReplicas|ComposeOrchestratorTests/upFailsDeployJobModeOnNonzeroExit|ComposeOrchestratorTests/upRejectsDeployJobRestartPolicy|ComposeOrchestratorTests/upRejectsServiceRestartPoliciesForDeployJobs|ComposeOrchestratorTests/upAllowsServiceRestartNoneForDeployJobs|ComposeOrchestratorTests/upAllowsDeployRestartPolicyNoneForDeployJobs|ComposeOrchestratorTests/upRejectsUnsupportedDeployModesAsAppleContainerRuntimeGaps|ComposeOrchestratorTests/upRejectsDeployRestartMaxAttemptsWithoutOnFailure'
```

Final local checks:

```sh
make check
make coverage-check
git diff --check
```

Optional Docker Compose parity target, kept out of CI:

```sh
make docker-compose-restart-policy-parity
```

This validates Docker Compose V2 `HostConfig.RestartPolicy` behavior for explicit no-restart policies that remain allowed for job services while restart-capable job policies remain blocked.

## container-compose Checks

- [x] I updated `DOCKER-COMPOSE-PARITY.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
