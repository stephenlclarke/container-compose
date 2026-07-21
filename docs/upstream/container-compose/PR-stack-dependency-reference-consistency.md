# Pull Request

## Summary

- Restore Compose's direct `container` and `containerization` lockfile pins.
- Align `Tools/release/stack-refs.json` with the Phase 2 runtime revisions.
- Make clean-checkout SwiftPM resolution deterministic again.

## Type of Change

- [x] Release and CI metadata correction
- [x] Dependency-graph reproducibility fix
- [ ] Apple Container API change
- [ ] Apple Containerization API change

## Apple-Shaped Boundary

No Apple-owned source changes are necessary. The change retains the existing
generic runtime APIs and modifies only Compose-owned dependency coordination.
It deliberately avoids a Compose-specific fallback in either fork: a correct
immutable lock graph is the narrowest fix for both local and GitHub Actions
builds.

## Commit Tracking

Apply this single Compose commit:

- `eb42ff7c95e21bcf173bdd501e98894172016fd6`
  `fix(release): align stack dependency refs`

The commit pins:

- `stephenlclarke/container` at
  `c194d298449ffbd0a8a30f3307e75900a0b11970`.
- `stephenlclarke/containerization` at
  `fe272b22c133bd82e319d3c91863fe11abe708a0`.

## Code Map

- `Package.resolved`: records the direct immutable source-control pins used by
  a clean Compose checkout.
- `Tools/release/stack-refs.json`: records those same revisions for the stack
  release and consistency gates.

## Validation

```console
CONTAINER_STACK_REPO=/Users/sclarke/github/container \
  python3 Tools/ci/check-stack-consistency.py
python3 -m unittest Tools.ci.test_check_stack_consistency
swift build --disable-automatic-resolution --product compose
```

The build above was run in a fresh detached worktree with no `Packages/` edit
overrides, confirming the checked-in graph rather than a local development
override.

## Compatibility and Risks

- The selected revisions are the same direct revisions already declared by
  `Package.swift` for the Phase 2 IPv6 networking slice.
- No service, Compose-file, CLI, guest, or container behavior changes.
- The focused consistency test and a clean locked build guard against this
  class of stale-reference drift before release publication.
