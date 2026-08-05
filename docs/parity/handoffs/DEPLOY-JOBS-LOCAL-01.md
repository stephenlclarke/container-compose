# DEPLOY-JOBS-LOCAL-01 Handoff

## State

`Verified`. The exact documented main dependency graph builds the candidate runtime, the focused tests pass, and the strict Docker/CLI certificate passes from a marker-protected root.

## User-visible contract

Docker Compose local mode accepts `deploy.mode: replicated-job` and `global-job` without introducing a job-completion wait or rejecting normal `restart` and `deploy.restart_policy` settings. Detached `up` returns with the service containers running, while `up --wait` uses ordinary running/healthy readiness rather than completion waiting. Swarm scheduling and task-per-node behavior remain out of scope.

## Implemented changes

- Removed the `isDeployJobService` restart-policy gate and its job-only rejection message.
- Removed the job-completion wait, its forced detachment behavior, and its exclusion from ordinary `up --wait` targets.
- Replaced rejection/wait regressions with five focused tests covering replicated/global restart projection, detached start, ordinary `--wait`, ordinary local replicas, and dependent-service convergence.
- Added `Tools/parity/check-compose-deploy-job-modes.sh` and `make docker-compose-deploy-job-modes-parity`. The script uses one Compose fixture to exercise Docker config, detached start, `--wait`, Docker HostConfig restart policies, and the candidate CLI dry-run path.

## Oracle and retained evidence

Evidence root: `/private/tmp/container-deploy-jobs-evidence.lCq5CP` with marker `.container-deploy-jobs-root`.

- Docker Compose `5.3.1`, Docker Engine `29.2.1`/API `1.53`, and Colima accept the original fixture. `up --detach` returned in `0.249409s`; `up --wait --wait-timeout 5` returned in `0.782011s`, with both `sleep` containers still running and no project residue after cleanup.
- Current Docker Compose `5.4.0`, Docker CLI `29.7.1`, and Engine `29.2.1` strictly revalidated that fixture against `alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc`; no uniquely named project container or network remained.
- Exact-main-stack `ContainerLaunchAdapterTests`, all five job-mode `ComposeOrchestratorTests`, and `Tools/parity/check-compose-deploy-job-modes.sh --strict` pass. The candidate CLI leg deliberately uses `--dry-run`; Docker runs the real detached and `--wait` fixture, while the focused candidate regressions cover orchestration decisions.
- The source, dependency, binary, image, and disposable-root fingerprint is retained at `/private/tmp/container-build-main-stack-evidence.Jkdz8E/BUILD-MAIN-STACK-01-fingerprint.json` under the `.container-build-main-stack-root` marker.

## Resolved build boundary

The historical blocker is preserved rather than discarded. The old main stack lacked archive-stream `copyIn`/`copyOut` overloads and `ContainerLogRequest`, so Compose could not construct its runtime adapter. The verified checkpoints are:

1. Containerization `5338e6685df56b8c15b49d0e7dd272a87abe0865`: `ArchiveReader` can honor an explicit `preserveOwnership: false` staging request.
2. Container `68cd7a6d9d97d3d7cbfe65080799a4779b96a333`: narrow request/error compatibility types and in-process create/run logging projection.
3. Compose: the copier uses the secure maintained path-copy/archive fallback when native archive streams are absent, while test-injected native streaming remains covered.

The exact graph still warns that local and remote Containerization identities conflict through Container. This future SwiftPM hard-error risk is dependency-harness hygiene, not a failed API build; it must remain tracked separately. Resolver-generated `Package.resolved` changes were restored and no dependency pin changed.

## Safe handoff

This contract needs no retry. Preserve both marker-protected evidence roots and the current fingerprint, retain the history above, and move the remaining Local Deploy work to CPU/generic reservation preservation and DeviceBroker-backed non-GPU requests. Do not fold Swarm scheduling, task-per-node behavior, or generic deployment work back into this verified job-mode contract. Slack END replies to the existing START thread `1785962702.085149`.
