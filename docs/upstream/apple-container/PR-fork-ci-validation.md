# Pull request: run supported validation in contributor forks

<!-- markdownlint-disable MD013 -->

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

`container` currently skips its reusable build job in every contributor fork.
That creates a false-green pull request: the workflow completes without proving
that source changes compile or pass tests. The fix keeps the Apple-owned guest
integration contract intact while using standard macOS capacity for the
non-virtualized checks that are valid in forks.

Related issue draft:
[ISSUE-fork-ci-validation.md](ISSUE-fork-ci-validation.md).

## Commit Tracking

- `c3b63f5204a9ad125ee1eae916df2e65c0449c2f` in
  `stephenlclarke/container` (`ci(validation): run fork macOS checks`).

This is one constructible generic CI pull request. It contains no Docker or
Compose compatibility policy.

## Implementation Details

- Select the Apple self-hosted ARM runner only for `apple/container`; all other
  repositories use the standard ARM macOS runner.
- Apply the Apple-managed Xcode path only on the Apple repository.
- Run unit tests in every repository.
- Keep kernel installation and guest integration exclusive to the Apple
  self-hosted runner.
- Keep coverage enabled for Apple pull requests and disable its
  integration-dependent path in forks.

## Testing

- [x] Tested locally
- [x] Added/updated workflow validation
- [x] Added/updated docs

```sh
make fmt
make protos
make container dsym docs test
actionlint .github/workflows/common.yml .github/workflows/pr-build.yml .github/workflows/merge-build.yml
git diff --check
```

The local test suite passed 929 tests. Guest integration remains deliberately
outside the fork runner contract and continues to run on the Apple self-hosted
runner.

## Compatibility Notes

- Apple pull requests keep the existing runner, Xcode selection, coverage, and
  guest integration suite.
- Fork pull requests now exercise the build and unit-test contract instead of
  being skipped.
- Release behavior is unchanged.

## Remaining Risks

- Standard hosted macOS runners cannot validate the guest-VM suite. The Apple
  self-hosted integration job remains the required coverage for that boundary.
