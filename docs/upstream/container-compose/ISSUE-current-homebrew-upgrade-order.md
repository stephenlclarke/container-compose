# Bug: Current Homebrew versions can prevent upgrades

<!-- markdownlint-disable MD013 -->

## I have done the following

- [x] I searched the existing issues.
- [x] I reproduced the issue using the `main` branch of this project.

## Steps to reproduce

1. Install the atomic Current pair published for Compose
   `12fe9e3223662f33c25cdaf285dafa65b2040599`. Both formulae have version
   `current.12fe9e322366`.
2. Publish the next green Current pair for
   `0e7d6e7386a068fb44f62d306127613814404aa5`. Both updated formulae have
   version `current.0e7d6e7386a0`.
3. Run:

   ```sh
   brew update
   brew upgrade stephenlclarke/tap/container-current \
     stephenlclarke/tap/container-compose-current
   ```

4. Observe that Homebrew reports both installed formulae as already current
   and retains `current.12fe9e322366`, even though the tap and `current` release
   point at `0e7d6e7386a068fb44f62d306127613814404aa5`.

Homebrew's version comparator confirms the cause: the source SHA is an
immutable identity but not a monotonic release sequence, and
`current.0e7d6e7386a0` does not sort above `current.12fe9e322366`.

## Problem description

Every successful exact-main package run publishes a newer atomic
`container-current` / `container-compose-current` pair. Users must be able to
consume that pair with an ordinary `brew upgrade`. A SHA-only formula version
can sort below an older SHA, causing Homebrew to leave both installed packages
stale while the tap and prerelease have advanced.

The Current formula version must place a monotonically increasing publication
identifier before the short source SHA. The source SHA remains visible for
traceability, and both formulae must continue to receive the exact same version
in one signed tap commit.

## Environment

- OS: macOS on the designated Apple silicon MacBook Pro release host
- Homebrew: local current Homebrew installation on 23 July 2026
- Container: `homebrew-main-211-271ba58e8884`
- container-compose: `0.7.0`, Current commit `12fe9e322366`

## Acceptance criteria

- A focused helper validates the workflow run number and full lowercase source
  SHA, then renders `current.<run-number>.<12-character-sha>`.
- Unit tests cover valid output, leading-zero normalization, invalid run
  numbers, invalid SHAs, and command-line success and failure.
- Release-policy tests require the package workflow to use the helper with
  `GITHUB_RUN_NUMBER` and `PUBLISH_SHA`.
- Homebrew's real `Version` comparator proves the generated version is newer
  even when the new SHA sorts below the installed SHA.
- Exact-main CI, CodeQL, Quality, Documentation, and SonarQube pass.
- The automatic Current publication updates both formulae in one signed commit.
- An ordinary `brew upgrade` installs both refreshed formulae without
  `reinstall`, uninstalling, or editing local Homebrew state.
- The installed runtime, Compose build information, live volume lifecycle, and
  typed-command VHS recording all pass after the upgrade.

## Implementation reference

Signed commit `057089c8957d609de3c8b16ad8d858e4088f666d`
(`fix(release): make Current Homebrew upgrades monotonic`) contains the release
orchestration fix, focused unit coverage, workflow policy assertion, and
operator documentation. The paired pull-request handoff provides the code map
and validation record.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
- [x] I removed secrets and private data from this report.
