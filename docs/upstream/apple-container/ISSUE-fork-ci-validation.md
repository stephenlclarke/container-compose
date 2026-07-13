# Bug: run meaningful validation in contributor forks

<!-- markdownlint-disable MD013 -->

## Bug Details

The reusable `container` build job is skipped whenever the repository is not
`apple/container`. A pull request in a contributor fork can therefore report a
successful workflow without compiling the project, checking generated protobuf
sources, or running any tests.

The integration suite requires the Apple-managed self-hosted macOS runner and
must remain there. Contributor forks should instead run the supported
non-virtualized validation on a standard macOS runner: formatting, protobuf
generation, build, documentation, packaging, and unit tests.

Requested shape:

- Choose the existing self-hosted runner only for `apple/container` and use a
  standard ARM macOS runner for every other repository.
- Keep the Apple-managed Xcode selection and guest integration suite limited to
  `apple/container`.
- Run the regular unit-test path in all repositories.
- Disable the integration-dependent coverage workflow in forks rather than
  publishing incomplete coverage artifacts.
- Keep this entirely generic; it must not add Docker or Compose policy.

## Upstream Search

- No open `apple/container` issue or pull request was found for fork runner
  selection or fork validation while preparing this draft.
- The requested change preserves the existing Apple runner, toolchain, and
  integration behavior. It only removes the unconditional fork skip.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
