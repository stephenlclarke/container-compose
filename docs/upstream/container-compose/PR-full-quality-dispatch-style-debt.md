# Clear the full hosted Swift quality gate

## Summary

Make the manual full Quality workflow a reliable prerelease gate by clearing
the accumulated SwiftLint and SwiftFormat debt in every non-legacy file it
selects.

## Commits to cherry-pick

1. `ac6d82e4a5b0a91cd222bc5e27372edde94cd6b1`
   `refactor(quality): clear full Swift lint gate`
2. `f5605fbe242fcbddcb24cc1da057d34aa0edbadc`
   `style(swift): format full quality surface`

The documentation commit containing this handoff is intentionally separate.

## Implementation

- Splits `ComposeArgumentRewriter` into focused extensions and moves nested,
  Bridge, commit, and version cases into a dedicated test source.
- Models watch exec input as a request value, reduces lifecycle-hook parameter
  counts, and wraps long watch operations without changing their call order.
- Separates network create argument construction from direct resource creation,
  reducing the original function's size and cyclomatic complexity.
- Uses failable UTF-8 conversion for encoder-produced JSON and retains explicit
  lossy decoding for arbitrary child-process bytes.
- Documents `io` as the deliberate public stream-handling abbreviation without
  renaming the API.
- Applies the current SwiftFormat policy mechanically to the remaining 17
  non-legacy files selected by full Quality validation.
- Documents the exact `quality.yml` dispatch required before Current
  publication.

## Compatibility

- No Compose command, option, normalized model, runtime request, or release
  artifact schema changes.
- The `CommandRunning` public API retains its existing `io` label.
- Process output preserves the prior replacement-character behavior for
  malformed UTF-8.
- Existing legacy exclusions are unchanged; no new file-wide lint exclusion is
  added.

## Validation

- [x] Full selected-path strict SwiftLint: 99 files, zero findings.
- [x] Full selected-path SwiftFormat lint: 99 files, zero findings.
- [x] Complete Swift suite: 1,117 tests passed.
- [x] Focused process runner suite: 12 tests passed, including malformed UTF-8.
- [x] Swift line coverage: 91.38%.
- [x] Go statement coverage: 90.06%.
- [ ] Complete matched-stack local release gate.
- [ ] Exact-main CI and CodeQL.
- [ ] Exact-main full Quality and Documentation workflows.
- [ ] Exact-main SonarQube quality gate and unresolved-issue check.
- [ ] Exact-main automatic Current package, Homebrew, and rendered demo checks.

## Reviewer notes

The large-looking `ComposeSignalProxy.swift` diff is indentation-only
SwiftFormat output. The other mechanical files similarly contain only policy
formatting. Behavioral refactors and their tests are isolated in the first
commit for review.

## Checklist

- [x] Signed Conventional source commits.
- [x] Unit coverage for the new process-output decoding helper.
- [x] No broad lint relaxation or newly excluded source file.
- [x] Build documentation updated.
- [ ] Signed Conventional documentation commit.
- [ ] Hosted and release evidence recorded after the final main push.
