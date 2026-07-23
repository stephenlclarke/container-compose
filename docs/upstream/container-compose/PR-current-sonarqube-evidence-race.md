# Pull request: retry Current publication while SonarQube evidence converges

<!-- markdownlint-disable MD013 -->

## Summary

- Add a bounded five-second retry around missing exact-main SonarQube job-step
  evidence for automatic `workflow_run` publication.
- Keep API read failures distinct and fail closed without retrying them as
  ordinary eventual consistency.
- Keep manual Current dispatch strict and unchanged.
- Add an executable shell harness for eventual success and authority failure,
  and update release-policy assertions to require the retry wrapper.

## Commit and code map

Signed commit `285a961a3fa37cb7b19325b1bf9fd4d29f087ada`
(`fix(release): wait for SonarQube job evidence`) is the reviewable
implementation:

- `.github/workflows/prebuilt-binaries.yml` adds
  `wait_for_successful_main_sonarqube_scan` and uses it only in the automatic
  main publication path.
- `Tools/release/test_capture_quality_snapshot.py` executes the extracted shell
  function and covers two stale reads followed by success plus the distinct
  authority-read failure.
- `Tools/release/test_container_stack_release.py` makes the bounded wait part
  of the release-policy contract.

No Compose runtime or Apple fork code changes. The patch is confined to release
orchestration and retains exact-main, successful-CI, successful-SonarQube, and
fresh-main checks before any release or Homebrew mutation.

## Validation

- Focused release policy: 78 tests passed.
- Quality snapshot policy: 20 tests passed.
- Complete release tools: 144 tests passed.
- CI tools: 14 tests passed.
- Coverage tools: 4 tests passed.
- `actionlint`, `git diff --check`, and `make check` passed.

The source runtime remains covered by the immediately preceding exact-stack
gate: 1,114 Swift tests, 91.39% Swift line coverage, 90.06% Go statement
coverage, 25 of 25 live runtime scenarios, and 56 of 56 strict Docker Compose
V2 contracts against Docker Compose 5.3.1.

Exact-main hosted workflow, SonarCloud, Current, Homebrew, checksum, and
rendered-GIF evidence are post-merge gates and must identify the final
documentation commit rather than this source commit alone.

## Checklist

- [x] Reproduced against one immutable CI and publisher run pair
- [x] Signed Conventional source commit
- [x] Bounded eventual-consistency retry
- [x] Fail-closed API error behavior retained
- [x] Executable regression coverage
- [x] Release and workflow checks
- [x] Signed Conventional documentation commit
- [ ] Exact-main hosted CI, Quality, CodeQL, and Documentation workflows
- [ ] Exact-main SonarCloud `OK` gate with zero unresolved issues
- [ ] Automatic Current packaging executes rather than skipping
- [ ] Exact-main Current, Homebrew, checksum, and rendered-GIF verification
