# Issue handoff: `up --exit-code-from` loses selected service status

## Problem

The Compose `up` path accepts `--exit-code-from SERVICE`, renders it in
dry-run output, starts the selected service, and waits for it. In a live macOS
guest runtime run, however, it returns generic orchestration status `5` instead
of the selected service's terminal status.

The regression fixture starts an `api` service that exits with `7`. Docker
Compose V2 semantics require `up --exit-code-from api api` to return `7`; the
current live path returns `5`.

## Scope and ownership

This is Phase 4 lifecycle/status-propagation work in `container-compose`. No
additional Apple runtime primitive has been identified: the matched runtime
can start and observe the selected container. The fix should remain in the
Compose orchestration layer unless a narrower runtime lifecycle defect is
demonstrated.

## Reproduction

With the matched local runtime stack and a freshly built guest image, run:

```console
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 \
swift test --disable-automatic-resolution --skip-build \
  --filter ComposeRuntimeTests.ComposeRuntimeSmokeTests/\
runtimeUpExitCodeFromReportsDocumentedOrchestrationStatus --no-parallel
```

The release-gate regression test asserts the observed status `5`, so the
current supported-but-partial behavior remains continuously verified. Phase 4
acceptance must change that assertion to the Docker Compose V2 status `7`.

## Expected behavior

The managed foreground `up` path returns the terminal status of the selected
service, after applying Docker Compose-compatible exit-control cleanup. It
must not substitute a generic orchestrator failure for that selected status.

## Current mitigation

`compose up --help` and `STATUS.md` mark `--exit-code-from` as partially
supported. The option remains visible and parsed; the help limitation explains
that its live selected-service status propagation is incorrect.
