# Current package publication must refresh a stale release runner safely

## Problem

The Current-package job uses a physical Apple-silicon self-hosted runner because it must start Container guests and produce the validated monitoring-stack VHS transcript. The runner had remained on an older GitHub Actions binary after an upstream release. Its action downloader repeatedly failed TLS downloads for `actions/checkout` before repository code could run, so the workflow could neither package nor publish the corrected Current recording.

GitHub's background runner updater is not sufficient for this failure mode: the job must first download an action to reach normal job execution. A maintenance invocation of the runner installer previously reported an existing runner as configured and returned without comparing it to the signed upstream release.

## Scope and boundary

This is Compose release-host maintenance. No Apple Container or Containerization change is involved: the Apple runtime remains isolated behind the existing package workflow, while Compose owns the runner bootstrap and package-publication reliability.

## Required change

- Fetch the latest macOS ARM64 runner metadata and require GitHub's published SHA-256 digest.
- On an existing runner, compare the installed listener version with the signed asset version.
- Download and verify the archive before stopping the service.
- Preserve the existing `.runner` registration and launchd configuration; replace only the runner program archive.
- Verify the installed listener version after extraction and restore the service if extraction or verification fails.
- Keep normal install, current-runner, digest-mismatch, failed-update, help text, and operator documentation covered by deterministic regression tests.

## Commit tracking

- `fix(release): refresh stale release runner safely`

## Code map

- `scripts/install-scheduled-release-runner.sh` compares the installed listener with GitHub's latest signed macOS ARM64 release and updates only when necessary.
- `Tools/release/test_install_scheduled_release_runner.py` provides isolated fake upstream/archive fixtures for normal and failure paths.
- `BUILD.md` documents the repeatable maintenance command and its safety contract.
