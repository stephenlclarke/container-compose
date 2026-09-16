# Issue 704: pin the Container debug-symbol packaging repair

## Problem

The retained 0.15.2 stable-release transaction completed the Xcode 27 and
Swift 6.4 Container build but failed while collecting debug symbols. Container
assumed that SwiftPM had emitted sidecar `.dSYM` bundles even though the built
executables contained valid embedded DWARF data. Container pull request
[#284](https://github.com/stephenlclarke/container/pull/284) materializes a
missing bundle with the active Xcode `dsymutil`, validates exact executable and
bundle UUID equality, and atomically publishes all eight shipped bundles.

Compose cannot resume the stable transaction against an unpublished or mixed
dependency graph. Its SwiftPM pin and release stack manifest must identify the
exact reviewed Container `main` revision, and that matched Compose revision
must publish successfully as Current before stable 0.15.2 promotion.

Container pull request #284 merged as
`353c7b3784fa790c413c5b5ef02431fbdb817690`; that immutable revision is the
dependency authority for this recovery.

## Required work

- Pin the exact Container `main` revision produced by pull request #284 in
  `Package.swift`, `Package.resolved`, and `Tools/release/stack-refs.json`.
- Preserve the reviewed Containerization and builder-shim revisions.
- Pass stack-consistency, source, test, SonarQube, and exact-head review gates.
- Publish and verify the coherent Current archive and paired Current Homebrew
  formulae before resuming the retained stable transaction.

Tracked by
[issue #704](https://github.com/stephenlclarke/container-compose/issues/704).
