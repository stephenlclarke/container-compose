# DEPLOY-JOBS-LOCAL-01 Handoff

## State

`Blocked`. The local Compose behavior change and its focused tests are implemented, but the exact candidate test/binary cannot currently be built. This contract is not verified and must not be represented as supported yet.

## User-visible contract

Docker Compose local mode accepts `deploy.mode: replicated-job` and `global-job` without introducing a job-completion wait or rejecting normal `restart` and `deploy.restart_policy` settings. Detached `up` returns with the service containers running, while `up --wait` uses ordinary running/healthy readiness rather than completion waiting. Swarm scheduling and task-per-node behavior remain out of scope.

## Implemented changes

- Removed the `isDeployJobService` restart-policy gate and its job-only rejection message.
- Removed the job-completion wait, its forced detachment behavior, and its exclusion from ordinary `up --wait` targets.
- Replaced rejection/wait regressions with five focused tests covering replicated/global restart projection, detached start, ordinary `--wait`, ordinary local replicas, and dependent-service convergence.
- Added `Tools/parity/check-compose-deploy-job-modes.sh` and `make docker-compose-deploy-job-modes-parity`. The script uses one Compose fixture to exercise Docker config, detached start, `--wait`, Docker HostConfig restart policies, and the candidate CLI dry-run path.

## Oracle and retained evidence

Evidence root: `/private/tmp/container-deploy-jobs-evidence.lCq5CP` with marker `.container-deploy-jobs-root`.

- Docker Compose `5.3.1`, Docker Engine `29.2.1`/API `1.53`, and Colima accept the fixture. `up --detach` returned in `0.249409s`; `up --wait --wait-timeout 5` returned in `0.782011s`, with both `sleep` containers still running and no project residue after cleanup.
- `docker-compose-5.3.1-job-local-result.json`, `candidate-baseline-dry-run.json`, `focused-test-fingerprint-pre.json`, `focused-test-fingerprint-main-stack.json`, and `focused-test-main-stack-blocker.json` retain the exact commands, fingerprints, and final compiler blocker.
- `swiftc -parse` passed for the changed source/test files. `bash -n` of the new parity script and `make -n docker-compose-deploy-job-modes-parity` passed.
- No coverage percentage is claimed: the focused test bundle was not constructed, so its new five-test coverage path could not run.

## Exact blocker

Two evidence-based build attempts were made; do not make a third resolver/build attempt in this slice.

1. The local `upstream/logging-driver-parity` Container worktree (`259878a427de7021b52e40e759d3b261150cc514`) pins Engine API `0.3.5` but its source references `WorkloadNetworkEndpoint`, which is unavailable in that graph.
2. The documented main stack—Container `bb4556286d31c3aad1c1d6d3168c8ae4d3ed8ee2`, Containerization `44fbfcb9c4191e42c79cc80a6d18062fee2b6718`, Engine API `4949e743675f00ec102f7acacdb4e990409e383f`—reaches `ComposeContainerRuntime` but cannot compile it. Current Compose calls archive `copyIn`/`copyOut` overloads missing from Container main and requires unavailable `ContainerLogRequest`.

Both failures occur before `ComposeCoreTests` is built. Resolver-generated `Package.resolved` changes were restored; no dependency pin changed.

## Safe resume

First align a single Compose/Container/Containerization/Engine API graph that exposes the existing archive-copy and logging request API expected by `Sources/ComposeContainerRuntime`. Then, with the source/dependency/binary/test-root fingerprint recorded, run only:

```bash
CONTAINER_PACKAGE_PATH=/path/to/matched/container \
CONTAINERIZATION_PACKAGE_PATH=/path/to/matched/containerization \
CONTAINER_ENGINE_API_PACKAGE_PATH=/path/to/matched/container-engine-api \
swift test --skip-update --filter 'up maps deploy restart policy for replicated jobs without a job-specific wait|up maps service restart policy for global jobs without a job-specific wait|up wait treats deploy job modes as ordinary running services|up treats deploy job mode replicas as ordinary local services|up does not gate dependent services on deploy job completion'
```

If that passes, build the candidate from the same fingerprint and run:

```bash
DOCKER_COMPOSE=/private/tmp/container-deploy-jobs-evidence.lCq5CP/docker-compose-5.3.1 \
CONTAINER_COMPOSE=/path/to/matched/compose \
Tools/parity/check-compose-deploy-job-modes.sh --strict
```

Only then update the state to `Verified` and remove the job-mode portion of the parity gap. Slack END must reply to the existing START thread `1785962702.085149`.
