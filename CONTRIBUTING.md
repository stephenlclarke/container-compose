# Contributing To container-compose

Thank you for helping improve `container-compose`. This project aims to stay
small, readable, and aligned with the design style of
[`apple/container`](https://github.com/apple/container), so changes should be
focused and easy to review.

## Pull Requests

Use pull requests for all changes.

1. Fork the repository or create a topic branch from `develop`.
2. Keep each pull request focused on one bug fix, feature, or documentation
   update.
3. Add or update tests for behavior changes.
4. Update documentation when behavior, commands, installation, or developer
   workflow changes.
5. Update [COMPATIBILITY.md](COMPATIBILITY.md) when runtime primitive support
   changes.
6. Run the validation described in [BUILD.md](BUILD.md) before requesting
   review.

Maintainers review pull requests before merge. Direct pushes to protected
branches should be limited to maintainers and automation that has passed the
required checks.

## Conventional Commits

Use Conventional Commits for commit messages and pull request titles:

```text
type(scope): short imperative summary
```

Common types include:

- `feat` for a user-facing feature.
- `fix` for a bug fix.
- `docs` for documentation-only changes.
- `test` for test-only changes.
- `refactor` for behavior-preserving code cleanup.
- `ci` for workflow or automation changes.
- `chore` for maintenance that does not affect runtime behavior.

Examples:

```text
feat(up): recreate services when config changes
fix(ps): filter containers by compose project label
docs(install): clarify plugin archive layout
```

## Quality Bar

Every code change should be covered by tests at the right level. Prefer small
unit tests for parsing, planning, naming, and command construction. Add
integration-style tests when a change crosses the Swift orchestrator and Go
normalizer boundary.

Coverage must stay above the project threshold. New fixes should not drop
coverage below 80 percent for the affected area, and the repository gate uses
the stricter threshold documented in [BUILD.md](BUILD.md).

## Coding Guidelines

- Keep orchestration logic in Swift and Compose normalization in the Go helper.
- Prefer the existing project structure over new abstractions.
- Keep unsupported Compose features explicit and actionable.
- Keep [COMPATIBILITY.md](COMPATIBILITY.md) aligned with supported runtime
  primitives.
- Run `make check` for fast lint and license-header validation before larger
  test runs.
- Use deterministic names, labels, and output ordering where possible.
- Match [`apple/container`](https://github.com/apple/container) naming,
  formatting, and error-reporting conventions when the equivalent pattern
  exists.
- Keep comments useful: document public APIs and non-obvious behavior, not
  obvious assignments.

## Keeping Protected Branches Safe

Third-party contributions must not be able to break `develop` or `main`.
Maintainers should keep these guardrails enabled:

- Require pull requests before merging to protected branches.
- Require passing validation and coverage checks before merge.
- Require maintainer review for external contributors.
- Restrict write access to trusted maintainers.
- Avoid running untrusted pull request code with write-scoped secrets.
- Keep one Conventional Commit per accepted issue on `develop`. If a pull
  request needs several fixup commits during review, squash those fixups before
  treating the issue as complete on `develop`.
- When promoting a tested batch from `develop` to `main`, preserve the issue
  commits rather than squash-merging the batch. This keeps `main` aligned with
  the reviewed issue history while avoiding one CI/SonarQube run per small fix.

Do not include credentials, tokens, certificates, private keys, or personal data
in pull requests, tests, examples, logs, or screenshots.

## Licensing

By contributing, you agree that your contribution is licensed under the Apache
License, Version 2.0, matching the project license.
