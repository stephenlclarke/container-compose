# Bug: select a compatible Swift toolchain in contributor forks

<!-- markdownlint-disable MD013 -->

## Bug Details

The reusable `container` build job now runs in contributor forks. GitHub-hosted
macOS 15 requires an explicit Xcode selection because its default Swift can be
older than the Swift tools 6.2 requirement in `Package.swift`. The hosted
`Xcode_26.3` installation supplies a compatible Swift 6.2 toolchain.

Release callers also export `BUILD_CONFIGURATION=release` for packaging. The
same environment reached `make test`, where `SocketForwarderTests` uses
`@testable import SocketForwarder`; release test bundles do not compile that
target for testing. Packaging can remain release-mode, but all test targets
must use a debug build configuration.

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
- Run unit, integration, and coverage test targets with
  `BUILD_CONFIGURATION=debug` in every repository, independent of the release
  configuration used to package artifacts.
- Disable the integration-dependent coverage workflow in forks rather than
  publishing incomplete coverage artifacts.
- Keep this entirely generic; it must not add Docker or Compose policy.

## Upstream Search

- [apple/container#1746](https://github.com/apple/container/pull/1746) pins
  Apple CI to Swift 6.3. The hosted fork runner uses its available compatible
  Swift 6.2 toolchain because this repository declares Swift tools 6.2.
- No open Apple issue or pull request was found for the hosted-fork toolchain
  selection. The change preserves Apple runner, toolchain, and integration
  behavior.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
