# Pull request handoff: restore the complete Phase 5 Builder release gate

## Summary

- Remove the local, milestone-only Builder-gap exception and its version guard.
- Restore unconditional execution of all Container integration suites.
- Add strict Docker Compose V2 plus optional matched-Apple-runtime parity for
  an existing Dockerfile outside its build context.
- Record Apple's upstream resolution and the exact signed fork ancestry.
- Leave external build-secret sources as the remaining Phase 5 adapter slice.

Closes the implementation described by
[the closure issue](ISSUE-phase5-builder-release-exception-closure.md) and
supersedes the temporary
[release-exception handoff](PR-phase5-external-dockerfile-release-gate.md).

## Type of change

- [x] Release validation
- [x] Docker Compose V2 integration coverage
- [x] Current parity documentation
- [ ] Compose command or schema behavior
- [ ] New Apple runtime API

## Ownership and upstream shape

The functional repair is already Apple-owned:
[`apple/container@d1d7635`](https://github.com/apple/container/commit/d1d763530df3c6a326dbae7f0c0a59a335808045).
The fork synchronizes that ancestry in signed commit
[`1bc3167`](https://github.com/stephenlclarke/container/commit/1bc31674629287f3386637db4c6d8652dc36602a)
and keeps its only follow-up,
[`abed15f`](https://github.com/stephenlclarke/container/commit/abed15fdd0cafe340f8aceb65080e4a88d0ceb0a),
limited to a fork-specific named lifecycle fixture. This Compose change only
removes expired release policy and adds adapter-level parity proof.

## Code map

- `scripts/CONTAINER_STACK_RELEASE.sh` removes the exception input and
  version/milestone guard.
- `Tools/ci/run-stack-release-validation.sh` runs the complete Container suite
  without a dynamically filtered suite list.
- `Tools/release/test_container_stack_release.py` fails if the exception or
  filter returns.
- `Tools/parity/check-compose-build-external-dockerfile.sh` compares config and
  bake path projection, then performs a real build and run through Docker
  Compose V2 and, when enabled, the matched Apple runtime.
- `Tools/parity/fixtures/build-external-dockerfile/` keeps the Dockerfile
  deliberately outside `build.context`.
- `Makefile` includes the new check in the aggregate parity target.
- `STATUS.md` and the two resolved issue handoffs record current support.

## Validation

```sh
bash -n scripts/CONTAINER_STACK_RELEASE.sh
bash -n Tools/ci/run-stack-release-validation.sh
python3 -m unittest \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_phase5_builder_suites_are_unconditionally_restored \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_hosted_stack_validation_excludes_virtualization_commands
CONTAINER_COMPOSE_LIVE=0 \
  DOCKER_COMPOSE_REFERENCE='docker compose' \
  make docker-compose-build-external-dockerfile-parity
make test
make coverage
make check
```

Results:

- Full Swift suite: 1,119 tests passed.
- Swift coverage: 91.42% (minimum 90%).
- Go normalizer coverage: 90.06% (minimum 85%).
- Full release-tool, CI-tool, ShellCheck, Markdown, formatting, lint, license,
  and stack-consistency checks: passed.
- Docker Compose V2 5.3.1 config, bake, build, and run fixture: passed.
- Matching live runtime at exact Container merge
  `ea20b242e763eb3e64d412c3dc2bbaa69639d2f4` and Builder digest
  `sha256:d993210e3960bce33a84e061d6cb96385b43277fe94a7492fd6c60b6317d2197`:
  passed on this MBP.
- The synchronized `TestCLIBuilder`, `TestCLIBuilderLocalOutput`, and
  `TestCLIBuilderTarExport` integration selection: 50 tests in three suites
  passed.
- The serialized `TestCLIBuilderLifecycleSerial` follow-up: 3 tests in one
  suite passed, followed by successful runtime cleanup.
- The prerequisite no-cache slice merged as verified main commit
  `69cec2369316eee77a36bb35c74b6e90297928c7`.
- Initial exact-head commit
  `eea99ebc698cdb5fb21ef9039d594ae2411db790` passed CI
  ([run 30072061271](https://github.com/stephenlclarke/container-compose/actions/runs/30072061271)),
  CodeQL
  ([run 30072061188](https://github.com/stephenlclarke/container-compose/actions/runs/30072061188)),
  and Documentation
  ([run 30072061213](https://github.com/stephenlclarke/container-compose/actions/runs/30072061213)).
  The final signed merge head, Current prerelease, and signed Homebrew pair
  remain pending.

## Commit tracking

- Compose implementation:
  `9ec28541d716a529743aa23d491345d9f7b5e79c`
  (`fix(release): restore phase five builder gates`).
- Compose documentation:
  `eea99ebc698cdb5fb21ef9039d594ae2411db790`
  (`docs(build): hand off builder gate closure`).
- Apple upstream: `d1d763530df3c6a326dbae7f0c0a59a335808045`.
- Signed Container synchronization:
  `1bc31674629287f3386637db4c6d8652dc36602a`.
- Signed fork fixture reconciliation:
  `abed15fdd0cafe340f8aceb65080e4a88d0ceb0a`.
