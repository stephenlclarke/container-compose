# Pull request handoff: bound the 0.7.0 external-Dockerfile release exception

## Summary

- Keep the ordinary stack release gate unchanged: it runs all Container
  integration suites.
- Add one explicit, local-only exception for the 0.7.0 milestone promotion.
- Exclude only `TestCLIBuilderSerial`, the suite exposing the tracked Phase 5
  external-Dockerfile Builder gap.
- Require an explicit maintainer reason, require milestone intent, reject any
  version other than `0.7.0`, and reject the exception in hosted validation.
- Update the current parity ledger so `build.dockerfile` is correctly marked
  partial rather than supported.

## Type of change

- [x] Release validation and documentation
- [ ] Compose command or schema behavior
- [ ] Apple runtime API

## Motivation and context

Phase 1 is complete and its changed runtime paths have full targeted unit and
matched-runtime integration coverage. The release candidate nevertheless
cannot pass the aggregate serial suite because Phase 5 has not yet implemented
Docker Compose-compatible external Dockerfile file transfer. Treating that as
a green test would be inaccurate; permanently skipping it would weaken later
releases. This change creates a narrow, self-expiring release control instead.

## Code map

- `scripts/CONTAINER_STACK_RELEASE.sh` accepts and bounds the exception.
- `Tools/ci/run-stack-release-validation.sh` derives every serial suite from
  the checked-out Container source except `TestCLIBuilderSerial` when, and
  only when, the local exception is set.
- `Tools/release/test_container_stack_release.py` proves normal validation,
  the exact filtered invocation, and hosted rejection.
- `STATUS.md` and [the issue handoff](ISSUE-phase5-external-dockerfile-paths.md)
  describe the live Phase 5 gap.

## Validation

```sh
bash -n scripts/CONTAINER_STACK_RELEASE.sh
bash -n Tools/ci/run-stack-release-validation.sh
python3 -m unittest Tools.release.test_container_stack_release
git diff --check
```

The release gate itself retains Container unit coverage, Containerization
coverage/integration, Compose CI, runtime smoke, and Docker Compose parity. In
the explicit 0.7.0 local exception lane it also runs every Container integration
suite except `TestCLIBuilderSerial`; the Phase 5 upstream issue preserves the
required future full-suite test coverage.

## Commit tracking

Compose implementation commit:
`4c7beb0e3e52ea5b0dd5e151be6b4af82b546bb5`
(`fix(release): bound phase five gate exception`).

## Upstream handoff

This release-control change is Compose-fork maintenance and is not an Apple
pull request. The corresponding Apple-shaped Phase 5 implementation is defined
by [the issue handoff](ISSUE-phase5-external-dockerfile-paths.md); it should be
made in generic Builder code, with its own focused unit and integration tests,
before this exception is ever considered again.
