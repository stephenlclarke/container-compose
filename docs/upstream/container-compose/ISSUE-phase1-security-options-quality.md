# Remove redundant security-option loop control

## Problem

`ComposeOrchestrator.runtimeSecurityOptions(for:)` deliberately consumes the portable Docker Compose security options `seccomp=unconfined`, `apparmor=unconfined`, and `label=disable` without emitting a macOS runtime argument. Its loop used `continue` as the terminal branch, although no code follows that branch in an iteration. SonarQube correctly reports that control statement as redundant (`swift:S3626`), leaving a quality finding after the underlying Phase 1 security-option behavior was implemented.

## Acceptance criteria

- Preserve the existing mapping of enforceable security options to generic runtime arguments.
- Preserve Compose-layer consumption of the portable macOS no-op forms.
- Preserve the pre-side-effect error for every other security option.
- Remove the reported redundant loop-control statement.
- Prove the adapter behavior with focused unit tests and the Docker Compose v2 security-option parity fixture.

## Scope and compatibility

This is a Compose-layer control-flow correction only. It does not add or remove a Docker Compose option, alter container runtime arguments, add a platform primitive, or change Linux, Windows, or macOS security semantics. No Apple fork change is required.

## Linked work

- Code change: `8af324a7ee90b7410849a208223ddfea8c6cd314` (`fix(security): simplify portable security option no-ops`)
- Related implementation handoff: `docs/upstream/container-compose/PR-security-opt-portable-noop-forms.md`

## Remaining risk

The strict parity fixture compares normalized Docker Compose v2 configuration. Its optional Engine dry-run is unavailable on this host because no Docker daemon is running; the repository's fallback intentionally reports that limitation rather than fabricating an Engine result.
