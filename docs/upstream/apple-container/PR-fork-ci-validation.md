# fix(ci): select a supported Swift toolchain for fork validation

<!-- markdownlint-disable MD013 -->

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

`container` now runs its reusable build job in contributor forks, but the
GitHub-hosted macOS 15 runner defaults to Xcode 16.4 and Swift 6.1. The
repository requires Swift tools 6.2, so `make protos` fails before it can build
or test the project. This repair keeps the Apple-owned guest integration
contract intact while selecting the hosted Swift 6.3 toolchain for the
non-virtualized checks that are valid in forks.

Related issue draft:
[ISSUE-fork-ci-validation.md](ISSUE-fork-ci-validation.md).

## Commit Tracking

- `c3b63f5204a9ad125ee1eae916df2e65c0449c2f` in
  `stephenlclarke/container` (`ci(validation): run fork macOS checks`) enabled
  fork validation and exposed the missing hosted-toolchain selection.
- `21a3b2f` in `stephenlclarke/container`
  (`fix(ci): select Swift 6.3 for fork checks`) restores the hosted
  toolchain selection.

This is a generic CI repair. It follows
[apple/container#1746](https://github.com/apple/container/pull/1746)'s Swift
6.3 policy without adding Docker or Compose compatibility policy.

## Implementation Details

- Select the Apple self-hosted ARM runner only for `apple/container`; all other
  repositories use the GitHub-hosted macOS 15 runner.
- Apply Apple-managed `Xcode_swift_6.3` on the Apple repository and
  `Xcode_26.3` on GitHub-hosted fork runners.
- Fail before generated-source work if the selected toolchain path is absent,
  and print the selected Xcode and Swift versions as build evidence.
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
npx --yes markdownlint-cli2 docs/upstream/apple-container/ISSUE-fork-ci-validation.md docs/upstream/apple-container/PR-fork-ci-validation.md
git diff --check
```

The local test suite passed 929 tests. Guest integration remains deliberately
outside the fork runner contract and continues to run on the Apple self-hosted
runner.

## Compatibility Notes

- Apple pull requests keep the existing runner, Xcode selection, coverage, and
  guest integration suite.
- Fork pull requests exercise the build and unit-test contract with the hosted
  Swift 6.3 toolchain instead of the incompatible default Swift 6.1 toolchain.
- Release behavior is unchanged.

## Remaining Risks

- GitHub-hosted runner images can remove named Xcode directories. The workflow
  fails before source generation with the missing path if that happens, rather
  than emitting a misleading Swift-tools-version failure later.
- Standard hosted macOS runners cannot validate the guest-VM suite. The Apple
  self-hosted integration job remains the required coverage for that boundary.
