# Issue 425: preserve receipt tuples at the release validation barrier

## Problem

The 0.13.1 stable release gate completed all four functional validation stages successfully, including the complete Container test and coverage stage, but stopped before documentation and publication. The validation barrier applied Nextflow `collect()` to seven-field receipt tuples and compared the flattened result with the number of expected stages. Because `collect()` flattens nested lists by default, four receipts became 28 fields and the cardinality check always failed.

Tracking issue: [`#425`](https://github.com/stephenlclarke/container-compose/issues/425).

## Required outcome

- Preserve each receipt tuple while collecting the validation barrier input.
- Keep documentation blocked until every expected functional validation receipt exists.
- Add a cheap executable Nextflow fixture that fails if tuple collection flattens the receipts.
- Retain the existing recoverable-session behavior so the corrected release gate can reuse completed stage checkpoints.
- Do not rerun product validation while proving the orchestration semantic.

## Acceptance evidence

- An isolated five-run Nextflow 26.04.6 reproduction demonstrates that bare `collect()` turns four two-field tuples into eight fields.
- The focused recovery fixture preserves four tuples with `collect(flat: false)` and still proves exact-session recovery.
- Focused release-policy tests pin the production barrier and executable fixture to the tuple-preserving form.
- Nextflow lint accepts the corrected graph.
- The retained 0.13.1 stable gate resumes from its completed validation checkpoints and reaches publication.

## Scope

This changes release orchestration and its recovery proof only. Product source, release artifacts, validation commands, documentation contents, and publication authority are unchanged.
