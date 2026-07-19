# Keep Current release evidence aligned with the validated CI lane

## Problem

The `current` package workflow accepts a successful `Validate` job from the
lightweight documentation/formula lane. That lane deliberately does not run
`Validate Runtime` or its SonarQube scan. The release staging step nonetheless
waited for an exact-commit SonarQube analysis, so a valid documentation-only
current release could wait until timeout despite having exact CodeQL evidence.

## Acceptance criteria

- Require exact SonarQube and CodeQL evidence when the validated CI run
  successfully ran the SonarQube scan.
- When the validated run produced no SonarQube scan, permit a `current` note
  with exact CodeQL evidence and a clear SonarQube omission statement.
- Keep stable release notes strict: they may not omit SonarQube evidence.
- Determine the policy from the exact workflow-run jobs and steps, not from
  branch-name heuristics.
- Cover the optional path with unit and workflow-contract tests.

## Scope and compatibility

This is release-controller policy only. It changes neither Compose runtime
behavior nor published stable-release quality requirements. It handles the
lightweight documentation/formula lane and an externally deferred SonarQube
scan without pretending that a missing scan succeeded.
