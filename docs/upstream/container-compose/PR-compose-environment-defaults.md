# Pull request: honor Docker Compose root environment defaults

## Summary

- Honor `COMPOSE_PROFILES` and comma-separated `COMPOSE_ENV_FILES` while preserving explicit `--profile` and `--env-file` precedence.
- Apply `COMPOSE_ANSI`, `COMPOSE_COMPATIBILITY`, `COMPOSE_PROGRESS`, `COMPOSE_REMOVE_ORPHANS`, `COMPOSE_IGNORE_ORPHANS`, and `COMPOSE_STATUS_STDOUT` at the Compose command boundary.
- Warn about undeclared project containers by default, remove them when requested, and suppress the warning when explicitly ignored.
- Preserve the caller working directory for source-checkout normalizer invocations so relative `COMPOSE_ENV_FILES` retain Docker Compose meaning.
- Add a Docker Compose V2/Colima local parity target to keep profile, env-file, compatibility-name, progress, and output-channel behavior reviewed together.

## Motivation and context

The CLI already accepted the related root flags and compose-go already supplied several environment defaults, but the plugin did not apply the remaining Docker Compose environment controls consistently. In particular, an environment-selected profile was lost in the normalizer, alternative root env files were ignored, and source-checkout execution resolved relative environment files from `Tools/compose-normalizer` rather than the user's directory.

The implementation follows Docker's documented [pre-defined Compose environment variables](https://docs.docker.com/compose/how-tos/environment-variables/envvars/) and keeps invalid `COMPOSE_PROGRESS` values as early command validation failures.

## Implementation details

- `ComposeEnvironment` is a narrow Compose-owned resolver with explicit truthy parsing; malformed boolean values remain disabled, matching the Docker Compose behavior used by the parity fixture.
- `GlobalOptions` gives an explicit flag precedence over its environment fallback, creates status/progress sinks on stdout only for `COMPOSE_STATUS_STDOUT`, and validates progress values before model loading or runtime mutation.
- `ComposeExecutionOptions` carries only two lifecycle defaults (`removeOrphans` and `ignoreOrphans`) plus a separate status emitter. The Core orphan finder is reused by `up`, `create`, `down`, `kill`, and one-off `run`; it neither adds a runtime API nor changes service-output routing.
- The source-checkout normalizer receives one private caller-directory value. It is used only to make relative `COMPOSE_ENV_FILES` values resolve from the invoking Compose process; installed helper execution keeps its native working directory.

## Scope boundary

This is a Compose-only policy and adapter change. It uses the existing `ComposeRuntimeSPI` composition boundary and the existing generic container discovery/lifecycle abstractions. No Apple `container`, `containerization`, or builder-shim change is required, and no new AOP-like runtime hook is introduced.

## Validation

```console
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter ComposeEnvironmentTests
swift test --disable-automatic-resolution --filter ComposeNormalizerTests
swift test --disable-automatic-resolution --filter ComposeOrchestratorTests
bash -n Tools/parity/check-compose-environment.sh
make docker-compose-environment-parity
make check
make swift-test
```

The parity target uses the configured Docker Compose V2 reference and local Colima daemon through the repository's normal `docker-compose-parity` wrapper. It covers profile activation, ordered root env-file override, explicit `--env-file` precedence, `COMPOSE_COMPATIBILITY` naming, `COMPOSE_PROGRESS` validation, and `COMPOSE_STATUS_STDOUT` routing. Orphan lifecycle branches remain deterministic Core tests because they require pre-existing project containers.

## Reviewer checklist

- [x] Compose-only behavior is concentrated at the environment and orchestration seams.
- [x] Explicit flags retain precedence over environment defaults.
- [x] No lower-runtime fork is changed or pinned.
- [x] Docker Compose V2 parity is executable locally and included in the aggregate parity gate.
- [x] `STATUS.md` records supported behavior and the Windows-only path conversion boundary.
