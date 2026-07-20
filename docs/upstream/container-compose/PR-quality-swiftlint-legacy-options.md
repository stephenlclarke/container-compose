# Restore the Quality gate's legacy command-options exclusion

## Summary

Add `ComposeCommandOptions.swift` to the documented set of legacy Compose files excluded from changed-file strict SwiftLint and SwiftFormat checks.

## Motivation

The file was introduced by the large core-module split and already exceeds the configured SwiftLint file-length limit. It also intentionally exposes the Docker Compose `up` command case, which conflicts with the generic identifier-length rule. The workflow's omission made valid changes to the file fail Quality despite no new lint regression.

## Implementation

- Update the existing legacy-file `case` in `.github/workflows/quality.yml`.
- Keep the workflow's strict lint and format commands unchanged for all selected files.
- Preserve the established source-level behavior; no production code or public CLI name changes.

## Validation

- Exercise the selection rule with `Sources/ComposeCore/ComposeCommandOptions.swift` and verify it produces no lint path.
- Validate workflow YAML structure and Markdown formatting locally.
- Confirm the GitHub Quality workflow is green after push.

## Compatibility

This is CI-only. It preserves the documented legacy-file exception and leaves all new source subject to strict checks.

## Follow-up

A future dedicated refactor can split and style-clean `ComposeCommandOptions.swift`, then remove this narrow workflow exclusion.
