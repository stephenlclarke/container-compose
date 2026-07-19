# Pull request: render release quality metrics as native Markdown

## Summary

Make package-release quality metrics visible even when GitHub cannot inline an
SVG release asset. The release note now emits its exact validated metrics as
native Markdown list rows and links to the same self-contained SVG as optional
downloadable evidence. It makes metric visibility independent of third-party
badge hosts and GitHub's SVG image renderer.

## Constructible commit

- `b98e0c673c3ea24185aef90061753c1c18b998c0`
  `fix(release): render quality snapshot natively`

Prerequisite owned-asset commits are documented in
`PR-release-owned-quality-snapshot.md`; this change deliberately leaves their
generation and retention behavior intact.

## Implementation

- `Tools/release/capture-quality-snapshot.py` turns the typed metric badges
  into native Markdown rows and emits an ordinary evidence-download link.
  It no longer produces `![...](...svg)` for release notes.
- `Tools/release/test_capture_quality_snapshot.py` asserts each of the fourteen
  validated metric rows, the self-contained evidence link, and the invariant
  that neither Current nor stable snapshots contain Markdown image syntax.
- `BUILD.md` records the renderer boundary and the invariant that visible
  release metrics must not depend on SVG image embedding.

## Verification

```sh
python3 -m unittest Tools/release/test_capture_quality_snapshot.py
python3 -m unittest discover -s Tools/release -p 'test_*.py'
make check
git diff --check
```

Hosted proof after the next Current publication:

1. Read the `current` release body and confirm it includes `### Validated
   metrics`, all available metric rows, and no `![` Markdown image embed.
2. Confirm the `quality-snapshot-current.svg` asset remains present with
   `image/svg+xml` content type.
3. View the release page and confirm the visible metrics are native text rather
   than an image placeholder.

## Compatibility and risk

This uses standard GitHub Markdown only. If an optional asset download ever
fails, visible metric evidence remains intact. The link preserves archival SVG
access without treating the renderer's ability to display SVG images as a
release correctness requirement.
