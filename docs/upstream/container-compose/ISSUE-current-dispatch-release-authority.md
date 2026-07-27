# Current publication rejects full-dispatch CI authority

Hosted issue:
[`stephenlclarke/container-compose#163`](https://github.com/stephenlclarke/container-compose/issues/163)

## Problem

Exact-main CI workflow
[`30233497821`](https://github.com/stephenlclarke/container-compose/actions/runs/30233497821)
passed all source, runtime, coverage, CLI smoke, and SonarCloud checks for
`181c40c663c8c790db1b36ed73a2d473fc02d5e6`.

The matching Current workflow
[`30234078316`](https://github.com/stephenlclarke/container-compose/actions/runs/30234078316)
correctly accepted that `workflow_dispatch` run while resolving its publish
context, but rejected the same authority after restoring the package cache.
The package job's second authority check adds `--event push` to its exact
commit query, so a successful full-validation dispatch can never satisfy it.

This contradicts the release policy already enforced by the publish-context
controller and prevents docs-only closeouts from publishing after their
required explicit full validation.

## Expected behavior

- Accept an exact-commit successful `main` CI run started by `push` or
  `workflow_dispatch`.
- Continue to reject pull-request, scheduled, failed, pending, non-main, and
  different-commit runs.
- Keep the second package authority check independent so a changed or deleted
  authority cannot pass between context resolution and artifact construction.
- Preserve stable candidate-bound authority unchanged.

## Apple-shaped boundary

This is a Compose release-policy correction. It changes no Apple runtime
source, public API, Windows path, or Docker Compose behavior.

## Acceptance

- The package authority query does not pre-filter to push events.
- Its local result filter explicitly permits only `push` and
  `workflow_dispatch`.
- Release-policy tests cover the exact query boundary.
- The failed Current workflow is rerun only after the correction reaches
  exact-main green CI and SonarCloud.
