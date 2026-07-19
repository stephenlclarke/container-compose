# Pull request: simplify portable security-option no-op handling

## Summary

Removes the SonarQube `swift:S3626` finding from the Compose security-option adapter without changing its behavior. The portable `seccomp`, `apparmor`, and SELinux-label no-op forms are still accepted and consumed at the Compose boundary, while unsupported values still fail before runtime side effects.

## Linked issue

`docs/upstream/container-compose/ISSUE-phase1-security-options-quality.md`

## Constructible commit

- `8af324a7ee90b7410849a208223ddfea8c6cd314` `fix(security): simplify portable security option no-ops`

## Apple-shaped boundary

This is deliberately Compose-only. Parsing, portable no-op consumption, and diagnostics belong in the Compose adapter; Apple runtime repositories retain only generic runtime primitives. No fork changes, new runtime API, or private implementation hook are required.

## Implementation

- Express the error condition as the inverse of the explicitly supported portable no-op forms.
- Keep `no-new-privileges` and `systempaths=unconfined` mappings unchanged.
- Keep `seccomp=unconfined`, `apparmor=unconfined`, and `label=disable` as no-op values for the macOS Linux guest.
- Keep all other `security_opt` values as Compose errors before resource creation.

## Verification

```sh
swiftformat Sources/ComposeCore/ComposeOrchestratorRuntimeSecurityOptions.swift --lint --swift-version 6.2
swiftlint lint Sources/ComposeCore/ComposeOrchestratorRuntimeSecurityOptions.swift
swift test --filter 'ComposeCoreTests\.ComposeOrchestratorTests/upMapsStandardSecurityOptionSpellings\(\)'
swift test --filter 'ComposeCoreTests\.ComposeOrchestratorTests/runConsumesStandardSecurityOptionNoOps\(\)'
DOCKER_COMPOSE=docker-compose CONTAINER_COMPOSE=.build/debug/compose ./Tools/parity/check-compose-security-opt.sh --strict
git diff --check
```

Both focused unit tests passed. The strict Docker Compose v2 fixture passed its normalized configuration comparison. Docker Engine was not available locally, so the script skipped only its optional Engine dry-run assertion and reported the fallback explicitly.

## Compatibility and risk

There is no user-visible behavior change: the same supported values produce the same runtime arguments, and the same unsupported values fail. The change is a source-level quality correction. The only environmental limitation is the unavailable optional Docker Engine dry-run noted above.
