# Issue 595: Complete recoverable builds and automatic versioning

Issue [#595](https://github.com/stephenlclarke/container-compose/issues/595)
closes the remaining gaps in the native Container-family build graph introduced
by pull request #594.

## Contract

- Plain `make` builds the complete five-repository stack; `make local-build`
  remains the explicit quick Compose-only path.
- SwiftPM scratch, Go artifacts, pins, bundles, and timing evidence live below
  marker-protected build state outside source checkouts.
- Every native operation and the whole graph have deadlines and durable timing
  records.
- Build identity covers exact source, dependencies, artifacts, toolchains,
  effective Swift SDK and target, and only the marked stack controller sections.
- An executable fail-once test proves root reuse, downstream recovery, Compose
  publication, and final bundle verification.
- Conventional Commit history selects automatic semantic versions; explicit
  reviewed selectors remain available for maintenance, security, and recovery.
- Maintained build and contribution documentation shows the build, test,
  recovery, Actions, and release flows.

## Evidence

The focused Python suites cover the complete graph, atomic pin implementation,
deadline and timing runner, semantic-version resolver, release workflow policy,
and scheduled workflow. Markdownlint and Actionlint validate the affected
documentation and GitHub Actions workflow. Final evidence will add a clean
native build, immediate warm rerun, exact-head review, and the 0.14.3 release
transaction.
