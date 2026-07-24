# Phase 4 release gate: Builder suite rename invalidates the bounded exception

> Historical release control. Phase 5 removes this exception completely; see
> [the closure handoff](PR-phase5-builder-release-exception-closure.md).

## Summary

Apple's container#2002 moved the build integration tests from the serial pass
into concurrent suites and renamed their source files. The pre-Phase-5 local
release exception still required the three old filenames, so the Phase 4
stable gate failed closed before it could run the otherwise unchanged test
partition.

## Scope

This is a release-policy reconciliation, not a runtime exception expansion.
The same three known Phase 5 Builder gaps remain deferred:

- external Dockerfiles exercised by `TestCLIBuilder`;
- local external-Dockerfile output exercised by
  `TestCLIBuilderLocalOutput`;
- direct and repeated tar export exercised by
  `TestCLIBuilderTarExport`.

The gate derives every other concurrent suite from the checked-out Container
tree and passes that exact set through `CONCURRENT_TEST_SUITES`. Serial suites
remain untouched. The exception is still local-only, requires an explicit
reason, is limited to milestone releases from `0.7.x` through `0.9.x`, and
expires fail-closed at Phase 5 version `0.10.0`.

## Expected behavior

- Missing any one of the three tracked upstream suite files fails closed.
- Every other concurrent and serial Container integration suite runs.
- Hosted validation cannot use the exception.
- Phase 5 removes the exception after implementing both Builder fixes.

## Reproduction

```sh
CONTAINER_STACK_RELEASE_PHASE5_BUILDER_GAPS_EXCEPTION_REASON='tracked Phase 5 work' \
  Tools/ci/run-stack-release-validation.sh \
  full \
  ../container-compose \
  ../container-builder-shim \
  ../containerization \
  ../container \
  ../homebrew-container-compose
```

Before this reconciliation the command reports:

```text
expected tracked Phase 5 Builder suite is missing: TestCLIBuilderSerial.swift
```

## Validation

```sh
python3 -m unittest \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_phase5_builder_gaps_exception_is_local_and_expires_at_phase5 \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_hosted_stack_validation_excludes_virtualization_commands
make check
```
