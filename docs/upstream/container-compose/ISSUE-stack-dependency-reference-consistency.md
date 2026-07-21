# Stack dependency references must remain atomically aligned

## Problem

The Phase 2 networking slice updated Compose's direct `container` and
`containerization` requirements, but its checked-in root lockfile and release
stack manifest retained the preceding revisions. A local `Packages/` edit
override can hide that difference; a clean SwiftPM checkout cannot. It then
attempts to resolve two distinct revisions of `containerization`, while the
release consistency gate also sees a stale `container` pin.

## Scope and boundary

This is Compose release metadata, not an Apple runtime feature. `container`
and `containerization` remain independent, generic repositories. Compose owns
the dependency graph that combines them, so the correction belongs in the
Compose lockfile and its stack-release manifest instead of adding a workaround
to either fork.

## Required behavior

- `Package.resolved`, `Package.swift`, and `Tools/release/stack-refs.json`
  name the same immutable `container` revision.
- The Compose and Container lockfiles name the same immutable
  `containerization` revision.
- A clean `swift build --disable-automatic-resolution --product compose`
  succeeds without a local package edit override.

## Commit tracking

- `eb42ff7c95e21bcf173bdd501e98894172016fd6` —
  `fix(release): align stack dependency refs`

## Validation expectations

- `Tools/ci/check-stack-consistency.py` accepts the complete stack graph.
- Its focused unit suite covers divergence detection.
- A fresh, unedited checkout builds the `compose` product using the committed
  lockfile.
