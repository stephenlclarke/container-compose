# fix(ci): validate release candidates with debug test bundles

<!-- markdownlint-disable MD013 -->

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

`container` runs its reusable build job in contributor forks, where the
GitHub-hosted macOS 15 image needs an explicit compatible Swift selection. The
hosted `Xcode_26.3` installation supplies the Swift 6.2 toolchain required by
this repository's Swift tools 6.2 declaration.

Release callers also package with `BUILD_CONFIGURATION=release`. That setting
previously leaked into `make test`, which fails to compile the
`@testable import SocketForwarder` test bundle in release mode. This repair
keeps release artifacts unchanged and explicitly uses debug test bundles for
unit, integration, and coverage validation.

Related issue draft:
[ISSUE-fork-ci-validation.md](ISSUE-fork-ci-validation.md).

This is a generic CI repair. It follows
[apple/container#1746](https://github.com/apple/container/pull/1746)'s toolchain
compatibility policy without adding Docker or Compose compatibility policy.

## Implementation Details

- Select the Apple self-hosted ARM runner only for `apple/container`; all other
  repositories use the GitHub-hosted macOS 15 runner.
- Apply Apple-managed `Xcode_swift_6.3` on the Apple repository and
  `Xcode_26.3` on GitHub-hosted fork runners.
- Fail before generated-source work if the selected toolchain path is absent,
  and print the selected Xcode and Swift versions as build evidence.
- Use `BUILD_CONFIGURATION=debug` for unit, integration, and coverage tests,
  even when the workflow packages release artifacts.
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
make container dsym docs
make BUILD_CONFIGURATION=debug test
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
  Swift 6.2 toolchain required by this repository.
- Release artifacts remain release-mode; test bundles are debug-mode.

## Remaining Risks

- GitHub-hosted runner images can remove named Xcode directories. The workflow
  fails before source generation with the missing path if that happens, rather
  than emitting a misleading Swift-tools-version failure later.
- Standard hosted macOS runners cannot validate the guest-VM suite. The Apple
  self-hosted integration job remains the required coverage for that boundary.
