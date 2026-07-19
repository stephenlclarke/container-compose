# Pull request: accept portable no-op security-option forms

## Summary

Completes the Compose-layer compatibility for security-option forms that are
already no-ops in the matched macOS Linux guest: bare no-new-privileges,
unconfined seccomp/AppArmor, and disabled SELinux labeling.

## Constructible commit

- `62a6d20e153ea2a4f4bee6e864771a15245d3ed7`
  `feat(security): accept portable no-op option forms`

## Apple-shaped boundary

No fork change is required. The Compose adapter owns Docker Compose parsing,
spelling normalization, diagnostics, and no-op consumption. Apple forks retain
only the generic, enforceable no-new-privileges primitive.

## Implementation

- Bare `no-new-privileges` becomes `no-new-privileges:true` at the generic
  runtime boundary.
- `seccomp=unconfined`/`seccomp:unconfined`,
  `apparmor=unconfined`/`apparmor:unconfined`, and
  `label=disable`/`label:disable` are accepted but never emitted as synthetic
  runtime arguments.
- Existing profile and label requests stay pre-side-effect errors.
- Swift and Go normalizer tests retain the original Compose spellings.
- One Docker Compose V2 YAML fixture verifies config parity and dry-run
  command construction.

## Verification

```sh
go -C Tools/compose-normalizer test ./...
swift test --filter 'ComposeNormalizerTests/normalizesComposeFileThroughComposeGo'
swift test --filter 'ComposeOrchestratorTests/(upMapsStandardSecurityOptionSpellings|runConsumesStandardSecurityOptionNoOps|upMapsNoNewPrivilegesSecurityOptionToRuntimeArguments|runMapsNoNewPrivilegesSecurityOptionToRuntimeArguments|upRejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources|runRejectsUnsupportedUserAndSecurityOptionFieldsBeforeCreatingResources)'
make docker-compose-security-opt-parity DOCKER_COMPOSE_REFERENCE=docker-compose
make coverage-check
make check
git diff --check
```

The focused tests and Docker Compose V2 5.3.1 config parity passed locally.
Docker Engine was unavailable, so the parity script skipped only its optional
Engine dry-run assertion.

## Non-goals

Security options that request an actual seccomp/AppArmor/SELinux policy remain
unsupported. The change does not claim Docker's default profiles, macOS host
isolation, Windows behavior, or a new generic runtime security API.
