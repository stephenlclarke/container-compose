# Pull request: run supported validation in contributor forks

<!-- markdownlint-disable MD013 -->

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

`containerization` currently reports a successful reusable workflow in a
contributor fork without running its build or test steps. The workflow should
exercise the checks that hosted macOS can support while preserving the existing
Apple self-hosted guest-image and integration contract.

Related issue draft:
[ISSUE-fork-ci-validation.md](ISSUE-fork-ci-validation.md).

## Commit Tracking

- `b0f78ca94534d99e0afeab6f168112a2d54cbe9a` in
  `stephenlclarke/containerization` (`ci(validation): run fork macOS checks`).

This is one constructible generic CI pull request. It is independent of Docker
and Compose compatibility behavior.

## Implementation Details

- Select the Apple self-hosted ARM runner only for `apple/containerization`;
  use the standard ARM macOS runner otherwise.
- Limit the Apple-managed Xcode path and Swiftly activation to the official
  repository.
- Run unit tests in every repository.
- Keep `vminitd` image generation, kernel retrieval, guest integration, image
  artifacts, and release image publishing on the official self-hosted runner.

## Testing

- [x] Tested locally
- [x] Added/updated workflow validation
- [x] Added/updated docs

```sh
make fmt
make protos
make containerization examples docs test
actionlint .github/workflows/containerization-build-template.yml
git diff --check
```

The local test suite passed 602 tests. Guest integration remains deliberately
exclusive to the Apple self-hosted runner.

## Compatibility Notes

- Official pull requests retain the full existing self-hosted build,
  integration, artifact, and release behavior.
- Fork pull requests now prove the supported build and unit-test contract.
- No public API or runtime behavior changes.

## Remaining Risks

- Hosted macOS runners cannot exercise the Virtualization-based guest suite.
  The official self-hosted integration job remains the required validation for
  that boundary.
