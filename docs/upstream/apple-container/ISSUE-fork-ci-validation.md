# Bug: select a compatible Swift toolchain in contributor forks

<!-- markdownlint-disable MD013 -->

## Bug Details

The reusable `container` build job now runs in contributor forks, but its
GitHub-hosted macOS 15 runner selects the default Xcode 16.4 toolchain. That
toolchain provides Swift 6.1, while `Package.swift` declares Swift tools 6.2 as
the minimum version. The workflow fails in `make protos` before it can build or
test the project.

The integration suite requires the Apple-managed self-hosted macOS runner and
must remain there. Contributor forks should run the supported non-virtualized
validation on a GitHub-hosted macOS 15 runner: formatting, protobuf generation,
build, documentation, packaging, and unit tests.

Requested shape:

- Choose the existing self-hosted runner only for `apple/container` and use a
  GitHub-hosted macOS 15 runner for every other repository.
- Keep the Apple-managed `Xcode_swift_6.3` selection and guest integration
  suite limited to `apple/container`.
- Select `/Applications/Xcode_26.3.app/Contents/Developer` in the hosted fork
  job, export it through `GITHUB_ENV`, and print the selected Xcode and Swift
  versions before generated-source work begins.
- Run the regular unit-test path in all repositories.
- Disable the integration-dependent coverage workflow in forks rather than
  publishing incomplete coverage artifacts.
- Keep this entirely generic; it must not add Docker or Compose policy.

## Upstream Search

- [apple/container#1746](https://github.com/apple/container/pull/1746) pins
  Apple CI to Swift 6.3. The fork repair follows that upstream toolchain policy
  while using the equivalent Xcode installation available on GitHub-hosted
  macOS 15 runners.
- No open Apple issue or pull request was found for the hosted-fork toolchain
  selection. The change preserves Apple runner, toolchain, and integration
  behavior.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
