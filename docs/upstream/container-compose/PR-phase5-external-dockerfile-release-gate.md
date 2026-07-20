# Pull request handoff: bound the 0.7.0 Phase 5 Builder-gap release exception

## Summary

- Keep the ordinary stack release gate unchanged: it runs all Container
  integration suites.
- Add one explicit, local-only exception for the 0.7.0 milestone promotion.
- Exclude only `TestCLIBuilderSerial` and `TestCLIBuilderTarExportSerial`, the
  suites exposing the tracked Phase 5 external-Dockerfile and tar-export
  Builder gaps.
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
Docker Compose-compatible external Dockerfile file transfer or the generic tar
output handoff for direct and repeated destinations. Treating either as a green
test would be inaccurate; permanently skipping them would weaken later
releases. This change creates a narrow, self-expiring release control instead.

## Code map

- `scripts/CONTAINER_STACK_RELEASE.sh` accepts and bounds the exception.
- `Tools/ci/run-stack-release-validation.sh` derives every serial suite from
  the checked-out Container source except the two exact tracked Builder suites
  when, and only when, the local exception is set. It fails closed if either
  suite is renamed or removed.
- `Tools/release/test_container_stack_release.py` proves normal validation,
  the exact filtered invocation, and hosted rejection.
- `STATUS.md` and [the external-Dockerfile handoff](ISSUE-phase5-external-dockerfile-paths.md)
  plus [the tar-export handoff](ISSUE-phase5-builder-tar-export.md) describe
  the live Phase 5 gaps.

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
suite except the two named failing Phase 5 Builder suites; the upstream handoffs
preserve the required future full-suite test coverage.

## Commit tracking

Compose implementation commit:
pending `fix(release): bound phase five builder gaps`.

## Upstream handoff

This release-control change is Compose-fork maintenance and is not an Apple
pull request. The corresponding Apple-shaped Phase 5 implementation is defined
by [the external-Dockerfile handoff](ISSUE-phase5-external-dockerfile-paths.md)
and [the tar-export handoff](ISSUE-phase5-builder-tar-export.md); it should be
made in generic Builder code, with its own focused unit and integration tests,
before this exception is ever considered again.
