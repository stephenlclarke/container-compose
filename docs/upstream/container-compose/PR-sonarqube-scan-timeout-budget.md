# Pull Request

## Summary

- Give exact-main Sonar analysis enough outer workflow time to complete all
  three configured scanner attempts.
- Retain the existing reachable-service fail-closed enforcement.
- Add a workflow-policy regression test and document the timing contract.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Closes [#154](https://github.com/stephenlclarke/container-compose/issues/154).

The Sonar target permits three attempts, each with a 300-second quality-gate wait, plus 20-second retry delays. Its GitHub Actions step allowed only ten minutes total. When SonarCloud accepted the exact revision but delayed processing, attempt one exhausted its wait and the outer deadline killed attempt two before the configured policy could finish.

This change raises only the outer workflow budget to 25 minutes. It does not skip Sonar, weaken quality-gate waiting, change retry count, or change the following API-aware enforcement step.

## Implementation Details

- `.github/workflows/ci.yml` budgets 25 minutes for `make sonar-scan`, covering
  three 300-second waits, scanner work, and two 20-second delays.
- `Tools/release/test_container_stack_release.py` locks the fail-closed scan
  shape and the 25-minute budget.
- `BUILD.md` records the main-branch timing and enforcement contract.

## Testing

- [x] `python3 Tools/release/test_container_stack_release.py` (62 tests)
- [x] `make check` (189 Python tests plus release, consistency, license, format,
  YAML, shell, and Markdown checks)
- [ ] Exact-head pull-request checks
- [ ] Exact-main CI with a passed SonarQube scan
- [ ] Exact-main Sonar analysis revision and quality gate

Docker Compose V2 and live Apple-runtime integration are not applicable to this CI-only timing correction. The preceding CC-001 source change retains its existing strict Docker Compose V2 and source-matched macOS runtime evidence.

## Compatibility

No Compose model, CLI, runtime, package, or Apple primitive changes. Successful fast Sonar scans are unchanged. Delayed scans can now consume the retry policy the Makefile already promises.

## Remaining Risks

- A SonarCloud incident that outlasts every configured attempt still fails
  exact-main CI while the API remains reachable, by design.
- The longest failure path can now consume up to 25 minutes instead of being
  killed at ten minutes.

## container-compose Checks

- [x] `BUILD.md` and the handoff documents are current; `STATUS.md` needs no
  change because Compose support does not change.
- [x] This pull request is focused on one issue.
- [x] The CI failure and exact-main run are linked in the issue handoff.
- [x] Conventional Commit and pull request title will be used.
- [x] This internal-only change will use `Release-Note: none`.
- [x] No upstream source change is imported.
- [x] The commit will be signed.
- [x] No credentials or private data are included.
