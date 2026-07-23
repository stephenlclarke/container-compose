# Bug: Current runtime upgrades still depend on SHA ordering

<!-- markdownlint-disable MD013 -->

## I have done the following

- [x] I searched the existing issues.
- [x] I reproduced the issue using the `main` branch of this project.

## Steps to reproduce

1. Publish a Current build after the package-workflow version repair.
2. Inspect both formulae in the atomic Homebrew tap commit.
3. Observe that the Compose formula is monotonically versioned:

   ```text
   version "current.849.bc8399014f87"
   ```

4. Observe that the matched runtime formula still depends only on the source
   identity:

   ```text
   version "current.bc8399014f87"
   ```

5. Publish a later Current build whose twelve-character SHA sorts below
   `bc8399014f87`.
6. Run an ordinary `brew upgrade` for the Current pair. Homebrew can recognize
   the Compose formula as newer while treating the matched runtime as older.

## Problem description

The Current lane already computes a monotonically increasing version from the
package workflow run number and source SHA. The Compose formula receives that
version, but the runtime-package step independently recreates a SHA-only
version. The resulting atomic tap commit contains matching assets but different
ordering rules.

Current is a paired stack: the runtime and Compose plugin must advance together.
Both formulae therefore need the same validated Current version. Stable
semantic releases must retain their existing semantic version.

## Environment

- Repository: `stephenlclarke/container-compose`
- Source: `bc8399014f878ac769360668e6df73d9c23a0731`
- Prebuilt Binaries run: `30004659566`
- Homebrew tap commit: `2aa3bc4fcf92fd1f3e2f42e3e45f54f53023904a`
- Compose formula: `current.849.bc8399014f87`
- Runtime formula: `current.bc8399014f87`

## Acceptance criteria

- Current runtime and Compose formulae use the same
  `current.<workflow-run-number>.<12-character-sha>` version.
- The version continues to come from the existing validated helper.
- Stable runtime and Compose formulae keep their semantic release version.
- The atomic tap update still changes only the two matched formula files.
- Release-policy tests reject the SHA-only runtime version.
- An ordinary Homebrew upgrade advances both installed Current formulae.

## Implementation reference

Signed commit `376ccadd5900aff24855e0872999e1d7851041ca`
(`fix(release): version Current runtime monotonically`) passes the validated
Current formula version into the runtime package step and adds focused
regression assertions. The paired pull-request handoff maps the code and
validation needed for upstream review.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
- [x] I removed secrets and private data from this report.
