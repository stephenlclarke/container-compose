# Bug: Current publication can skip a green main build

<!-- markdownlint-disable MD013 -->

## I have done the following

- [x] I searched the existing issues.
- [x] I reproduced the issue using the `main` branch of this project.

## Steps to reproduce

1. Push a release-workflow change to `main` that selects the heavyweight CI
   path.
2. Wait for CI run `29993094792` to complete successfully. Its jobs include a
   successful `Validate Runtime`, an intentionally skipped lightweight
   `Validate`, and a successful aggregate `Validate`.
3. Inspect the automatically triggered Prebuilt Binaries run `29994015477`.
4. Observe that its first jobs-API response contains a null conclusion while
   the aggregate result is still becoming visible:

   ```text
   Skipping package publish because CI Validate results were ,skipped,success.
   ```

5. Observe that the workflow completes successfully with `Package` skipped,
   leaving the mutable Current release and Homebrew pair stale even though the
   exact-main CI and SonarQube scan passed.

## Problem description

GitHub can deliver a completed `workflow_run` event before every aggregate job
conclusion is populated by the jobs API. The package gate correctly permits
successful validation jobs plus intentionally skipped companions, but it reads
those conclusions only once. A transient null value therefore fails the
authority predicate and produces a successful skipped package run.

The gate must retry only the unsettled jobs-API state, retain the existing
bounded retry policy, and continue to fail closed on API errors. Once all
conclusions are populated, the existing success-or-intentional-skip authority
predicate remains unchanged. If conclusions never settle, the workflow must
fail visibly rather than silently leave Current stale.

## Environment

- Repository: `stephenlclarke/container-compose`
- Source: `0129f71313c2dbf2d7443c8617a79125c300c1e3`
- CI run: `29993094792`
- Prebuilt Binaries run: `29994015477`
- Event: successful `main` push followed by `workflow_run`
- Host: GitHub-hosted Ubuntu publish-context runner

## Acceptance criteria

- The package gate retries when any relevant `Validate` or `Validate Runtime`
  conclusion is null or the relevant job set is temporarily empty.
- The retry is bounded and uses the existing authenticated GitHub authority
  query.
- Populated failure or cancellation conclusions are not retried and still fail
  the normal authority predicate.
- API read failures and exhausted unsettled evidence fail the workflow visibly.
- Unit tests execute the settled-state predicate for null, empty,
  success/skipped, and terminal-failure inputs.
- Release-policy tests require the retry helper and its fail-closed behavior.
- The automatic `workflow_run` path publishes Current after exact-main CI and
  SonarQube pass; no manual package dispatch is needed.

## Implementation reference

Signed commit `22d8ac7a8eec9f82ba3a52a390426ebd083939b4`
(`fix(release): wait for complete CI authority`) contains the bounded authority
retry, executable regression coverage, policy assertions, and operator
documentation. The paired pull-request handoff maps the focused code and
validation.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
- [x] I removed secrets and private data from this report.
