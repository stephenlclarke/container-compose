# Pull request: accept unconfined seccomp at the Compose boundary

## Summary

Adds Docker Compose V2-compatible handling for
`security_opt: seccomp=unconfined`. The Compose adapter preserves the value in
configuration and consumes it before command rendering because the macOS Linux
guest already runs workload processes without a seccomp filter.

## Constructible commit

- `4124fd494b5ed5e61e55c730e1f8326fc168b05e`
  `feat(security): accept unconfined seccomp option`

## Apple-shaped boundary

No fork change is required. Keeping this compatibility no-op in Compose avoids
a Docker-specific API in Apple `container` or `containerization`. Profile
support remains a future generic guest-runtime concern; it is deliberately not
emulated by the Compose adapter.

## Implementation

- `ComposeOrchestratorRuntimeSupport.swift` accepts only the exact
  `seccomp=unconfined` spelling, filters it from runtime arguments, and retains
  existing no-new-privileges forwarding.
- Orchestrator tests cover managed `up`, one-off `run`, combined options, and
  early rejection of unsupported options.
- Swift and Go normalizer tests prove the config model retains the value.
- `Tools/parity/check-compose-security-opt.sh` uses one Compose YAML fixture
  to compare Docker Compose V2 config output and local dry-run rendering.
- `STATUS.md` records the distinction between the unconfined baseline and
  unsupported seccomp profiles.

## Docker Compose V2 parity contract

```yaml
services:
  api:
    image: alpine:3.20
    security_opt:
      - no-new-privileges:true
      - seccomp=unconfined
```

Both Compose implementations retain the two values in config output. The
local dry run forwards only `no-new-privileges:true`; it intentionally omits
`seccomp=unconfined` because no generic runtime action is necessary.

## Verification

```sh
go -C Tools/compose-normalizer test ./...
swift test --filter 'ComposeNormalizerTests/normalizesComposeFileThroughComposeGo'
swift test --filter 'ComposeOrchestratorTests/(upConsumesUnconfinedSeccompSecurityOption|runConsumesUnconfinedSeccompSecurityOption|upMapsNoNewPrivilegesSecurityOptionToRuntimeArguments|runMapsNoNewPrivilegesSecurityOptionToRuntimeArguments|upRejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources|runRejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources)'
make docker-compose-security-opt-parity DOCKER_COMPOSE_REFERENCE=docker-compose
make check
git diff --check
```

The local checks passed against Docker Compose V2 5.3.1. Docker Engine was not
available, so the parity script correctly skipped only its optional Engine
dry-run assertion.

## Compatibility and non-goals

Existing no-new-privileges behavior is unchanged. The accepted spelling is
limited to `seccomp=unconfined`; seccomp profile paths, AppArmor, SELinux, and
all other unsupported security options remain pre-side-effect errors. This
does not imply macOS host isolation, a default Docker seccomp profile, or
Windows security-option support.
