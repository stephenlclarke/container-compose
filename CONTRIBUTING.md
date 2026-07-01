# Contributing To container-compose

Thank you for helping improve `container-compose`. This project aims to stay
small, readable, and aligned with the design style of
[`apple/container`](https://github.com/apple/container), so changes should be
focused and easy to review.

The contributor workflow intentionally follows the applicable parts of
[`apple/container`](https://github.com/apple/container/blob/main/CONTRIBUTING.md)
and its delegated
[`apple/containerization` contributing guide](https://github.com/apple/containerization/blob/main/CONTRIBUTING.md).
That keeps this repository easier to compare, review, and potentially offer
upstream with minimal reshaping.

## Pull Requests

Use pull requests for all changes.

1. Fork the repository or create a topic branch from `main`.
2. Keep each pull request focused on one bug fix, feature, or documentation
   update.
3. Sign every commit with a GitHub-supported signature method such as SSH or
   GPG.
4. Discuss substantial features or design changes in an issue before writing a
   large patch.
5. Add or update tests for behavior changes.
6. Update documentation when behavior, commands, installation, or developer
   workflow changes.
7. Update [STATUS.md](STATUS.md) when current runtime support or blockers
   change.
8. Run the validation described in [BUILD.md](BUILD.md) before requesting
   review.

Maintainers review pull requests before merge. Direct pushes to protected
branches should be limited to maintainers and automation that has passed the
required checks.

Use the issue templates when reporting bugs, requesting features, or tracking a
Compose compatibility gap. Use [SUPPORT.md](SUPPORT.md) for usage questions,
security routing, and deciding whether a report belongs in an issue or a
discussion.

## Maintainer Development Cycle

For Stephen-owned stack work, keep `main` as the current integration branch in `container-builder-shim`, `containerization`, `container`, and `container-compose`. Start a short-lived branch only when it makes review or version slicing clearer. When a non-main branch has been squashed or merged back to `main`, delete it locally and remotely unless it is still needed for an open review.

Most work does not need the release helper. Use `CONTAINER_STACK_RELEASE.sh` only at a version boundary: `plan` to inspect clean four-repo state, `start-dev VERSION_SELECTOR --execute` to open the next `develop/VERSION` slice, and `tag-current --execute` to mark the current `main` state as a stable source tag after the validated slice has been squashed back. GitHub Actions publishes `develop/VERSION` as `VERSION-pre` for `container-compose-pre` and semantic tags as stable releases for `container-compose`.

apple/container uses squash-and-merge for upstream pull requests, so make the
pull request title and body clear enough to stand alone as the final change
description. Use imperative wording, describe what changed, and include the
reason for the change.

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

## Upstream Adoption Friction

Keep every contribution easy for apple/container maintainers to assess:

- Prefer direct [`apple/container`](https://github.com/apple/container) APIs
  where available and keep CLI compatibility fallbacks explicit.
- Preserve the Swift orchestration and Go `compose-go` normalization boundary
  described in [DESIGN.md](DESIGN.md).
- Keep unsupported Compose surfaces explicit in [STATUS.md](STATUS.md)
  or the relevant `docs/upstream/` handoff, separating plugin gaps from
  apple/container runtime primitive gaps.
- Follow the Apache License, Version 2.0, and keep license headers current with
  `make update-licenses`.
- Use `make fmt`, `make check`, and `make pre-commit` so formatting and license
  checks stay close to apple/container's Hawkeye-based workflow.
- Avoid editor-specific root `.gitignore` entries. Use a global Git ignore file
  for personal editor or machine files.
- Keep AI-assisted changes explainable. Contributors should understand and be
  able to justify every line they submit.

## Coding Guidelines

- Keep orchestration logic in Swift and Compose normalization in the Go helper.
- Prefer the existing project structure over new abstractions.
- Keep unsupported Compose features explicit and actionable.
- Keep [STATUS.md](STATUS.md) aligned with current dependency pins, runtime
  blockers, and validation state.
- Run `make check` for fast lint and license-header validation before larger
  test runs.
- Use deterministic names, labels, and output ordering where possible.
- Match [`apple/container`](https://github.com/apple/container) naming,
  formatting, and error-reporting conventions when the equivalent pattern
  exists.
- Keep comments useful: document public APIs and non-obvious behavior, not
  obvious assignments.

## Keeping Protected Branches Safe

Third-party contributions must not be able to break `main`, release tags, or active `develop/VERSION` slices.
Maintainers should keep these guardrails enabled:

- Require pull requests before merging to protected branches.
- Require passing validation and coverage checks before merge.
- Require maintainer review for external contributors.
- Restrict write access to trusted maintainers.
- Avoid running untrusted pull request code with write-scoped secrets.
- Keep pull requests focused on one accepted issue or coherent change. If a
  pull request needs several fixup commits during review, squash those fixups
  before merge when they do not carry useful review history.
- Preserve meaningful issue commits when merging a tested batch. Avoid
  combining unrelated changes just to reduce CI runs.

Do not include credentials, tokens, certificates, private keys, or personal data
in pull requests, tests, examples, logs, or screenshots.

## Code Of Conduct

Contributors are expected to follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md),
which points to Apple's community standard used by apple/container and
Containerization.

## Licensing

By contributing, you agree that your contribution is licensed under the Apache
License, Version 2.0, matching the project license.
