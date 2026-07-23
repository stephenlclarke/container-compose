# Pull request: wait for complete CI authority before Current

<!-- markdownlint-disable MD013 -->

## Summary

- Retry the transient jobs-API state where a completed CI workflow still has a
  null aggregate validation conclusion.
- Preserve the existing successful-or-intentionally-skipped authority policy
  once every relevant conclusion is populated.
- Fail visibly on API errors or evidence that never settles, instead of
  completing successfully with a stale Current release.
- Add executable predicate coverage and update release-operator documentation.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Exact-main CI run `29993094792` passed, including its SonarQube scan, but its
automatic Prebuilt Binaries run `29994015477` observed the conclusions
`null, skipped, success` during publish-context resolution. The existing
one-shot query treated the transient null as failed authority, skipped
packaging, and still reported a successful workflow.

The `workflow_run` event is authoritative for completion, but GitHub's jobs API
can lag briefly while aggregate conclusions settle. The new helper makes that
specific state retryable for at most twelve five-second intervals. It does not
retry populated failures, weaken exact-main or SonarQube requirements, or turn
API errors into missing evidence.

## Commit and code map

Signed commit `22d8ac7a8eec9f82ba3a52a390426ebd083939b4`
(`fix(release): wait for complete CI authority`) is the focused
implementation:

- `.github/workflows/prebuilt-binaries.yml` adds
  `wait_for_complete_validate_conclusions`, then applies the existing authority
  predicate only after every selected conclusion is populated.
- `Tools/release/test_container_stack_release.py` executes the settled-state
  `jq` predicate for null, empty, success/skipped, and terminal-failure inputs
  and locks down the fail-closed workflow policy.
- `Tools/release/test_capture_quality_snapshot.py` keeps the shared transient
  GitHub-authority contract aligned with the helper.
- `BUILD.md` documents the jobs-API settling window and publication invariant.

No Compose runtime or Apple fork code changes. Stable semantic publication,
Current freshness checks, SonarQube authority, immutable assets, attestations,
and atomic Homebrew updates are unchanged.

## Testing

- [x] Complete release-tool suite: 154 tests passed.
- [x] Executable settled-state classifications cover
  `null/skipped/success`, empty, `skipped/success`, and `failure/skipped`.
- [x] `actionlint` for the package workflow.
- [x] Markdown lint for `BUILD.md` and this handoff.
- [x] Python compile validation and `git diff --check`.
- [ ] Complete matched-stack local release gate.
- [ ] Exact-main CI, CodeQL, Documentation, Quality, and SonarQube.
- [ ] Automatic Current publication without manual dispatch.
- [ ] Current checksums, attestations, signed tap pair, ordinary Homebrew
  upgrade, installed runtime smoke, named-volume persistence, and typed-command
  VHS verification.

The immediately preceding full matched-stack gate passed Builder coverage,
646 Containerization unit tests and 175 of 177 integrations with two expected
GPU skips, 1,135 Container unit tests and 381 integrations with 51.57% combined
line coverage, 1,114 Compose Swift tests, 153 release-tool tests, 25 live
Compose scenarios, and all 56 strict Docker Compose 5.3.1 parity targets. The
final gate below reruns the same stack with this workflow-only repair included.

## Compatibility and risk

The change affects only Current publish-context authority resolution. A normal
jobs response adds no delay. A transient null or empty response is retried for
at most 55 seconds. Populated failures reach the unchanged predicate
immediately, while API failures and exhausted unsettled evidence stop
publication visibly.

Manual `workflow_dispatch` authority is unchanged because it resolves a
completed exact-main CI run independently. Stable releases and formula repair
retain their existing gates.

## container-compose Checks

- [x] `BUILD.md` and `docs/upstream/` are current.
- [x] This change is focused on one reproduced release defect.
- [x] Runtime and release review notes are attached.
- [x] Commit and proposed pull-request title use Conventional Commits.
- [x] The commit includes a user-facing `Release-Note:` trailer.
- [x] The implementation commit is signed.
- [x] No credentials, tokens, keys, personal data, or registry details are
  included.
