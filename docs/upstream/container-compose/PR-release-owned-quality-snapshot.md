# Pull request: make release quality snapshots release-owned

## Summary

Replace the fourteen live Shields image requests in package notes with one
self-contained quality-snapshot SVG uploaded as a GitHub release asset. This
removes the partial-rendering failure mode while preserving the exact validated
SonarQube and CodeQL evidence, metric colours, and accessible text.

## Constructible commit

- `2101ad08bc9ccb7d8d09d7f8998d7301093be324`
  `fix(release): own quality snapshot assets`

## Implementation

- `Tools/release/capture-quality-snapshot.py` produces typed metric data,
  renders the deterministic SVG, and emits Markdown pointing only to the
  release-owned asset.
- `.github/workflows/prebuilt-binaries.yml` supplies distinct Current and
  stable asset names, stages the SVG with the package assets, and retains the
  Current SVG after release finalization.
- `BUILD.md` documents the owned-asset evidence contract.
- Unit tests cover metric escaping, image self-containment, CLI asset output,
  and the workflow/retention contract.

## Verification

```sh
python3 -m unittest Tools/release/test_capture_quality_snapshot.py
python3 -m unittest Tools/release/test_release_notes.py
python3 -m unittest Tools/release/test_container_stack_release.py
make check
git diff --check
```

The next Current build provides the hosted proof: its rendered release page
loads one `quality-snapshot-current.svg` asset from GitHub rather than relying
on external badge requests. The requested stable promotion uses the same
validated release path with `quality-snapshot.svg`.

## Compatibility and risk

The generated SVG uses only standard shapes and text, is uploaded with the
release package assets, and carries no executable content or external fetch.
If SonarQube is unavailable in the already-supported CodeQL-only path, the
release note retains its explicit textual omission rather than claiming a
missing SVG snapshot.
