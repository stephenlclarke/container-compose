# Pull request: verify static quality badges before publishing release notes

## Summary

Restore individual static SonarQube-style quality badges in Current and stable
release notes, and make GitHub-proxied badge delivery a required release gate.
Each publication uses a unique static delivery key. Before release notes can be
published, the controller renders their exact badge Markdown through GitHub,
fetches all resulting Camo URLs, and parses every response as SVG. This closes
the unverified image-proxy delivery boundary that let the former two-badge
failure become a public release note.

## Constructible commit

- `aa09331ce8ff7c255584ef436c42aaefd5bd34af`
  `fix(release): verify static quality badge delivery`

This supersedes the visible-note portion of `b98e0c673c3ea24185aef90061753c1c18b998c0`
while retaining its important release-asset rule: the composite SVG remains a
downloadable evidence artifact and is not embedded inline.

## Implementation

- `Tools/release/capture-quality-snapshot.py` renders each typed metric as a
  static Shields-compatible badge and includes a publication-specific cache key.
  It parses GitHub's Markdown response, verifies the ordered canonical sources,
  retries transient Camo delivery failures, and rejects non-SVG or malformed
  payloads.
- `.github/workflows/prebuilt-binaries.yml` passes the exact source commit,
  GitHub run ID, and run attempt as the delivery key and enables verification for
  both branch-backed Current and tag-backed stable publication paths.
- `Tools/release/test_capture_quality_snapshot.py` covers all fourteen static
  badges, CodeQL-only snapshots, Current/stable equality, workflow wiring,
  successful Camo validation, and missing or malformed image regression cases.
- `BUILD.md` documents the exact release invariant and its failure behavior.

## Verification

```sh
python3 -m py_compile Tools/release/capture-quality-snapshot.py Tools/release/test_capture_quality_snapshot.py
python3 -m unittest Tools/release/test_capture_quality_snapshot.py
python3 -m unittest discover -s Tools/release -p 'test_*.py'
bash -n Tools/release/publish-github-release.sh
git diff --check
```

Hosted verification after publication:

1. Read both `current` and the promoted stable release body; confirm a single
   static-badge row contains every available metric and no native metric list
   replaces it.
2. Confirm each release-note image resolves through GitHub Camo with a valid
   `image/svg+xml` response, including Code Smells and Coverage.
3. View both pages and confirm every badge renders without a placeholder.
4. Confirm the owned `quality-snapshot-*.svg` release asset remains available
   as optional evidence.

## Compatibility and risk

The only new operational dependency is deliberately strict: a temporary
Shields or GitHub Camo failure delays publication instead of publishing a
partially rendered quality block. The release note's metric values remain
static evidence for its exact commit, and the unique delivery key prevents a
previous proxy failure from poisoning a later publication.
