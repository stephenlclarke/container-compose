# Keep the Builder deferral bounded through the pre-Phase-5 releases

## Problem

The local stable-release helper documented the three known Phase 5 Builder
integration gaps as a temporary exception, but accepted the exception only
when the candidate version was exactly `0.7.0`. That release is already
immutable. The completed Phase 3 stable candidate is `0.8.0`, and the Phase 4
stable lane is `0.9.x`; both must continue to validate every in-scope suite
without incorrectly claiming that the separately scheduled Phase 5 Builder
work is complete.

The mismatch made the release policy contradict the current handoff: the
exception remained limited to the same three named Phase 5 suites in local
validation, yet the release helper rejected the explicit reason before the
Phase 3 gate could run.

## Required behavior

- Accept the explicit exception only for milestone releases in the `0.7.x`,
  `0.8.x`, and `0.9.x` pre-Phase-5 lanes.
- Continue to require a non-empty maintainer reason.
- Continue to omit only `TestCLIBuilderSerial`,
  `TestCLIBuilderLocalOutputSerial`, and
  `TestCLIBuilderTarExportSerial`.
- Continue to run every other Container integration suite.
- Continue to reject the exception in hosted validation.
- Fail closed from `0.10.0`, the Phase 5 stable lane, so Phase 5 cannot ship
  until all three suites pass.

The policy must not bypass Current source/package identity, the local matched
stack gate, Docker Compose V2 parity, hosted CI, SonarQube, CodeQL, signed-tag
verification, release-asset provenance, or paired Homebrew verification.

## Reproduction

With the completed Phase 3 candidate checked out, run:

```sh
CONTAINER_STACK_RELEASE_INTENT=milestone \
CONTAINER_STACK_MILESTONE_SOAK_OVERRIDE_REASON='explicit maintainer authorization' \
CONTAINER_STACK_RELEASE_PHASE5_BUILDER_GAPS_EXCEPTION_REASON='tracked Phase 5 Builder work' \
make release VERSION_SELECTOR=-+-
```

Before the correction, the helper stopped before validation with:

```text
CONTAINER_STACK_RELEASE_PHASE5_BUILDER_GAPS_EXCEPTION_REASON is permitted only for 0.7.0, not 0.8.0
```

## Acceptance criteria

- [x] Phase 3 `0.8.0` and Phase 4 `0.9.x` candidates can enter the bounded
  local validation lane.
- [x] Maintenance or security intent cannot use the exception.
- [x] Versions before `0.7.0`, `0.10.0`, and later versions reject it.
- [x] The exact three-suite filter and hosted rejection are unchanged.
- [x] Regression tests exercise accepted and rejected versions.

## Resolution

Implemented by
[`c2cd899f30bff81047ffdf164ee3565306ba7e7e`](https://github.com/stephenlclarke/container-compose/commit/c2cd899f30bff81047ffdf164ee3565306ba7e7e)
(`fix(release): expire builder deferral at phase five`).
