# Pull request: map unconfined guest system paths from Compose

## Summary

Completes the Compose adapter for Docker Compose V2
`security_opt: systempaths=unconfined` and `systempaths:unconfined`. Both
spellings remain visible in normalized config output and become the one generic
runtime argument understood by the Apple-shaped `container` fork.

## Constructible commits

- `container`: `687c2beec63e3de5a76f50ff81ac394f14dbf35b`
  `feat(security): support unconfined guest system paths`
- `container` handoff: `25fe60c`
  `docs(security): add guest system path handoff`
- `container-compose`: `c0331abed938051b1941e78dece6395e1238cb14`
  `feat(security): map unconfined guest system paths`
- `containerization`: no source change. Its existing
  `LinuxContainer.Configuration.maskedPaths` and `.readonlyPaths` fields are
  the generic primitive used by the fork.

## Apple-shaped boundary

- `container-compose` owns Docker Compose spelling, error diagnostics, config
  parity, and the canonical equals-form CLI argument.
- `container` owns a generic `unconfinedSystemPaths` configuration outcome and
  clears only guest OCI masked/read-only path lists.
- `containerization` remains unchanged and contains no Compose or Docker API.

This does not introduce a Compose protocol, Docker type, host-specific policy,
or broad security-option pass-through in either fork.

## Implementation

- `ComposeOrchestratorRuntimeSupport.swift` recognizes both system-path
  spellings and renders `systempaths=unconfined`.
- Orchestrator tests cover colon-form `up`, equals-form `run`, and exact
  unsupported diagnostics.
- Swift and Go normalizer tests preserve the Compose spelling.
- `check-compose-security-opt.sh` extends its Docker Compose V2 YAML fixture
  to cover both forms and validates the canonical dry-run runtime argument.
- A guarded Compose runtime smoke test starts a service with `cap_drop: ALL`,
  inspects the persisted generic setting, and verifies no `/proc/sys`
  read-only override appears in the initial process.
- `STATUS.md` records the completed runtime capability and the remaining
  profile-based security-option gap accurately.

## Verification

```sh
go -C Tools/compose-normalizer test ./...
swift test --filter 'ComposeOrchestratorTests/(upMapsUnconfinedSystemPathsSecurityOptionToRuntimeArguments|runMapsUnconfinedSystemPathsSecurityOptionToRuntimeArguments|upRejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources|runRejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources)'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 COMPOSE_TEST_BINARY="$PWD/.build/debug/compose" \
  CONTAINER_BIN=/Users/sclarke/github/container/bin/container \
  swift test --filter 'ComposeRuntimeSmokeTests/runtimeServiceClearsGuestSystemPathOverridesWithoutAddingCapabilities' --no-parallel
CONTAINER_COMPOSE="$PWD/.build/debug/compose" DOCKER_COMPOSE=docker-compose \
  ./Tools/parity/check-compose-security-opt.sh --strict
make coverage-check
```

All listed checks passed locally. Coverage was 91.38% for Swift and 85.50% for
Go. Docker Compose V2 5.3.1 config parity passed for both spellings. Docker
Engine was unavailable, so the script skipped only its optional Engine dry-run
assertion; the direct matched-guest Compose runtime test passed separately.

## Compatibility and non-goals

Existing projects are unchanged unless they specify this supported value.
`systempaths=unconfined` does not imply `privileged`, cannot circumvent
`cap_drop`, and does not expose macOS host namespaces or filesystems. SELinux,
AppArmor, and seccomp policy/profile requests remain unsupported until there is
an enforceable guest runtime primitive. Windows-only security forms remain out
of scope.
