# Quality gate runs strict lint on legacy command options

## Problem

The changed-file Quality workflow excluded the large pre-existing Compose command and orchestrator files that predate the strict SwiftLint gate, but omitted `Sources/ComposeCore/ComposeCommandOptions.swift`. Any valid feature change touching that file caused the workflow to lint its historical contents and fail on its established `file_length` and required `up` command-case violations. The result was a false red Quality gate unrelated to the submitted behavior.

## Scope

This is a CI path-selection defect. It does not change Compose runtime behavior, does not relax SwiftLint for newly introduced source files, and does not disable an individual lint rule.

## Expected behavior

The changed-file gate must apply strict SwiftLint and SwiftFormat checks to new and style-compliant Swift files, while consistently excluding every documented legacy command/orchestrator file until it is separately refactored to comply. Changes to `ComposeCommandOptions.swift` must therefore not re-run known legacy violations.

## Verification

- Confirm the workflow's selection case excludes `Sources/ComposeCore/ComposeCommandOptions.swift`.
- Confirm Quality executes successfully for the correction.
- Retain the full local test and coverage validation from the preceding anonymous-volume identity slice.

## Compatibility and risk

The change only restores the gate's existing legacy-file policy. Future new Swift files remain subject to strict lint. The legacy file should be split and modernized in a dedicated cleanup change before removing this exclusion.
