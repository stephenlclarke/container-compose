# Phase 5: retire the Builder release exception

## Problem

The pre-Phase-5 stack release gate could exclude exactly three Container
integration suites after an explicit, local-only milestone exception:
`TestCLIBuilder`, `TestCLIBuilderLocalOutput`, and
`TestCLIBuilderTarExport`. That temporary control was correct while the matched
runtime reproduced the external-Dockerfile and tar-delivery failures, but
retaining it after the generic runtime was fixed would allow a Phase 5 stable
release to omit required Builder coverage.

## Upstream resolution

Apple [`container@d1d7635`](https://github.com/apple/container/commit/d1d763530df3c6a326dbae7f0c0a59a335808045)
fixed the shared Builder startup race and moved the complete build coverage into
parallel suites. The fork preserves Apple ancestry in signed merge commit
[`1bc3167`](https://github.com/stephenlclarke/container/commit/1bc31674629287f3386637db4c6d8652dc36602a);
signed commit
[`abed15f`](https://github.com/stephenlclarke/container/commit/abed15fdd0cafe340f8aceb65080e4a88d0ceb0a)
only reconciles the named lifecycle fixture with fork behavior.

The restored generic coverage includes:

- `TestCLIBuilder`: an existing Dockerfile outside its build context;
- `TestCLIBuilderLocalOutput`: distinct Dockerfile and build-context paths;
- `TestCLIBuilderTarExport`: direct, directory, repeated-directory, and
  invalid tar destinations.

No Apple runtime patch is required beyond synchronizing the accepted upstream
change, and no Compose workaround should recreate the generic file or output
transfer.

## Required Compose change

1. Delete `CONTAINER_STACK_RELEASE_PHASE5_BUILDER_GAPS_EXCEPTION_REASON` and
   its milestone/version policy.
2. Delete the three-suite filter from local stack validation.
3. Run the complete Container suite in both full and hosted release modes.
4. Add a Docker Compose V2 fixture that projects, builds, and runs an existing
   Dockerfile outside its context through both live engines.
5. Mark the external-Dockerfile and generic tar-export entries complete while
   retaining external build-secret sources as the remaining Phase 5 adapter
   gap.

## Acceptance

- Policy tests prove that neither release script contains the former exception
  variable or a `CONCURRENT_TEST_SUITES` override.
- `make docker-compose-build-external-dockerfile-parity` passes in strict
  Docker Compose V2 mode and live matched-runtime mode.
- The exact synchronized `TestCLIBuilder`, `TestCLIBuilderLocalOutput`, and
  `TestCLIBuilderTarExport` suites pass.
- Full unit, coverage, formatting, lint, stack-release, and GitHub workflow
  gates pass at the exact signed Compose commit.
- The Phase 5 prerelease is published and verified before this slice is marked
  complete.
