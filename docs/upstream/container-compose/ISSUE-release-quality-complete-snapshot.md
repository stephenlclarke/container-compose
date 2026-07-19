# Require complete static quality evidence for every release note

## Problem

The mutable `current` release at `462605ffa9d50ed6e35c28daa76ebfc470e9d012` selected the completed documentation-only CI run that triggered package publication. That run correctly had no SonarQube scan, but a later successful full CI run for the exact same `main` commit did have a passed SonarCloud analysis. The release controller used only the triggering run's step list, published a three-badge CodeQL-only snapshot, and omitted the eleven static SonarQube badges despite complete exact-commit evidence being available.

This is both a correctness and presentation defect. A release note must either show the complete static fourteen-badge evidence set for its source commit or remain unpublished; it must not silently publish a partial quality block because CI lanes race.

## Acceptance criteria

- Current and stable release notes always contain the complete fourteen-badge static SonarQube and CodeQL snapshot plus the downloadable self-contained SVG evidence asset.
- Current publication accepts an exact-commit successful `main` CI run with a passed `Validate Runtime` / `SonarQube scan`, whether the CI was started by `push` or by an explicit full-validation `workflow_dispatch`.
- The release controller recognises either `Validate` or `Validate Runtime` as the active CI validation lane and still requires every observed validation job to be successful or intentionally skipped.
- A documentation-only CI run without an exact successful SonarQube scan leaves the existing Current release untouched; a manual Current package request fails with an actionable message instead of publishing partial evidence.
- A transient SonarCloud or CodeQL evidence failure blocks publication rather than falling back to a CodeQL-only release note.
- Unit tests cover the exact-main scan selection, manual full-CI event, missing-Sonar rejection, and removal of every CodeQL-only publication path.

## Scope and compatibility

This is a Compose-owned release-controller correction. It changes no Apple runtime primitive, Compose file behavior, fork, image, release tag, or Homebrew formula API. It deliberately trades a delayed Current publication for accurate, complete release evidence.
