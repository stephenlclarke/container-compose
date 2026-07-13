# Bug: run meaningful validation in contributor forks

<!-- markdownlint-disable MD013 -->

## Bug Details

The reusable `containerization` build job is skipped whenever the repository is
not `apple/containerization`. Pull requests in contributor forks can therefore
complete without compiling the library, regenerating protobuf sources, building
examples, documentation, or unit tests.

Apple's self-hosted runner is still required for the guest image and
Virtualization-based integration suite. Contributor forks should run the
supported non-virtualized checks on a standard ARM macOS runner instead of
skipping the entire job.

Requested shape:

- Select the existing self-hosted runner only for `apple/containerization` and
  a standard ARM macOS runner for forks.
- Limit Apple-managed Xcode and Swiftly setup to the official repository.
- Run formatting, protobuf regeneration, library/example/documentation builds,
  and unit tests in all repositories.
- Limit guest image construction, integration, image artifacts, and releases
  to the official self-hosted runner.
- Keep this generic CI behavior free of Docker or Compose policy.

## Upstream Search

- No open `apple/containerization` issue or pull request was found for fork
  runner selection or fork validation while preparing this draft.
- The change preserves the official runner's complete guest integration and
  release behavior.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
