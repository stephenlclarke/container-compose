# Preserve exact SonarQube evidence after stable metric retention expires

## Problem

Stable release `0.10.0` promotes Compose commit
`42b737dcda830f79b3f0993212e97fefe179f427`. Its exact hosted CI run
`30089845474` completed the `SonarQube scan` step successfully with
`sonar.qualitygate.wait=true`, and GitHub retains a successful
`SonarCloud Code Analysis` check for the same commit. The exact CodeQL analysis
is also retained with zero results across 34 rules.

Before the stable package workflow staged its release notes, later `main`
analyses replaced the promoted commit in SonarCloud's public analysis and
measure-history APIs. The release controller consequently waited for data that
could no longer reappear and failed after its 30-minute poll window, even though
the exact quality-gate and CI authorities remained available.

Using the latest `main` metrics would misrepresent the immutable release.
Dropping SonarQube entirely would hide passed exact-commit evidence. The stable
path needs an explicit retention policy that does neither.

## Acceptance criteria

- Current builds continue to require the full exact-commit SonarQube metric
  history and never use retained-evidence fallback.
- Stable publication prefers the full fourteen-badge SonarQube and CodeQL
  snapshot whenever the exact metric history remains available.
- When stable metric history has expired, publication requires all of:
  - a successful `SonarCloud Code Analysis` check attached to the promoted
    commit by the `sonarqubecloud` GitHub App;
  - a successful `SonarQube scan` step in a successful exact-commit `main` CI
    run triggered by `push` or `workflow_dispatch`;
  - an exact-commit CodeQL analysis without warnings or errors.
- The fallback snapshot labels the quality gate as passed and historical
  SonarQube metrics as expired, links the retained authorities, and states that
  no later metrics were substituted.
- Missing, failed, mismatched, or unreadable authority blocks publication.
- Transient SonarCloud metric API failures are not reclassified as retention.
- A stable retry executes release-control scripts from the verified workflow
  commit while package source and contents remain bound to the immutable signed
  tag, so the policy can be corrected without retagging.
- Unit tests and a live exact-commit release-tool invocation cover the policy.

## Scope and compatibility

This is a Compose-owned release-controller correction. It changes no Compose
model behavior, Apple runtime primitive, fork, package content, semantic tag, or
Homebrew formula API. The fallback is stable-only and preserves the immutable
release's exact source identity.
