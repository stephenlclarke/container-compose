# Issue 446: remove the managed Sonar `gtimeout` dependency

## Problem

Exact-main CI run
[33721423678](https://github.com/stephenlclarke/container-compose/actions/runs/33721423678)
passed source checks, both policy suites, the full coverage gate, and the built
CLI smoke. It then failed before starting SonarQube because GitHub's managed
macOS image does not provide Homebrew's `gtimeout` command.

The repository already owns a tested process-group supervisor at
`Tools/ci/run-command-with-deadline.py`. Requiring a second, undeclared host
timeout implementation makes the quality gate runner-dependent and prevents a
validated main commit from reaching Current packaging.

## Required work

- Use the repository-owned deadline runner for the normal SonarQube scan.
- Use the same runner for canonical-main SonarQube restoration.
- Preserve the 1,500-second deadline and 30-second graceful cleanup window.
- Assert that neither workflow depends on `gtimeout`.

## Acceptance boundary

The issue is complete when the focused deadline and workflow-policy tests pass,
exact-head review is clear, and main CI reaches the SonarQube quality result on
managed macOS without requiring an unpinned Homebrew package.

Related issue: [#446](https://github.com/stephenlclarke/container-compose/issues/446).
