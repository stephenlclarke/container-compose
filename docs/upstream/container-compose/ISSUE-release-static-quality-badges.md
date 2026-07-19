# Restore verified static quality badges in release notes

## Problem

Package release notes historically rendered the exact SonarQube and CodeQL
snapshot as fourteen individual static badges. During the 2026-07-19 Current
publication, two badge images displayed GitHub's broken-image placeholder even
though direct requests to the static Shields sources and the subsequently
rendered Camo URLs returned valid SVGs. The exact transient response is not
retained by GitHub, but the release controller had no check of the image-proxy
delivery boundary and could publish a partially rendered note.

Replacing all badges with native Markdown prevented placeholders but regressed
the intended release-note presentation. Reintroducing static images without a
delivery gate would allow the same partially broken release note to recur.

## Acceptance criteria

- Render every available snapshot metric as an individual static
  Shields-compatible badge in both `current` and semantic release notes.
- Give each publication a unique static delivery key so a bad proxy cache entry
  cannot be reused by a later pre-release or stable release.
- Before publication, use GitHub's Markdown renderer to obtain the exact Camo
  image URLs that the release page will use, fetch every image, and require a
  valid `image/svg+xml` payload for each one.
- Retry transient delivery failures and fail the release if any badge remains
  missing, non-SVG, or malformed.
- Retain the release-owned composite SVG as downloadable evidence without
  embedding it inline.
- Cover static rendering, unique delivery keys, Current/stable equivalence,
  workflow wiring, successful proxy verification, malformed payloads, and
  missing rendered images with unit tests.

## Scope and compatibility

This is a release-controller-only correction. It changes neither Compose
behavior nor the collected quality data, release tags, binaries, asset
retention, or Homebrew formulae. It restores the existing compact static-badge
presentation while making image delivery a publication gate.
