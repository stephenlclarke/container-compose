# Render release quality metrics without an inline SVG dependency

## Problem

The release controller already generates a deterministic, release-owned quality
snapshot SVG and GitHub serves it as `image/svg+xml`. However, GitHub release
pages can render a Markdown image whose source is a release-asset SVG as a
broken image. The owned asset is valid, but the visible quality snapshot then
contains no readable metrics.

This is separate from the former third-party Shields outage: the failure is in
the release-page image renderer, so substituting another SVG asset cannot make
the release body reliable.

## Acceptance criteria

- Render every validated SonarQube and CodeQL metric directly as native GitHub
  Markdown in the release note.
- Do not emit any Markdown image syntax in a quality snapshot.
- Retain the deterministic SVG as an optional, downloadable evidence artifact.
- Keep the exact commit provenance and the CodeQL-only omission behavior.
- Cover the no-image invariant, all metric rows, SVG generation, CLI output,
  and the existing Current-asset retention workflow contract with tests.

## Scope and compatibility

This is a release-controller-only correction. It does not alter Compose
behavior, metric collection, quality gates, retention, release assets, tags, or
Homebrew formulae. Existing release notes remain historical; the next Current
or stable publication uses renderer-independent metric text.
