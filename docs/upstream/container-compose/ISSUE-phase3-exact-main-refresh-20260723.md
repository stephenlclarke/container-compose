# Phase 3 exact-main refresh after stable promotion

## Context

Phase 3 stable release `0.8.0` passed the complete local and hosted release
gates and remains immutable. Installed-package validation then exposed a
daemon-state-dependent Homebrew smoke, and the follow-up Container workflow
exposed a second packaging-only failure when GitHub retention removed its
historical formula-template archive.

While those fixes were being validated, Apple merged Containerization
[`450d44e`](https://github.com/apple/containerization/commit/450d44e),
which replaces quadratic EXT4 child lookup with an insertion-ordered name
index. The final Current prerelease must contain that new upstream change and
all packaging corrections rather than publishing a graph already behind
Apple.

## Required behavior

- Keep the published `0.8.0` executable assets and signed tag immutable.
- Resolve Compose to the reviewed Container and Containerization
  documentation tips.
- Preserve the builder-shim revision.
- Require all exact-main CI, SonarQube, CodeQL, package, checksum, Homebrew,
  provenance, and VHS gates before accepting Current.
- Keep the README support-fork snapshot aligned with the release manifest.

## Resolution

The signed Compose commit
[`3decbde6d0293a6eb64b5fd6bba642e0b0330d99`](https://github.com/stephenlclarke/container-compose/commit/3decbde6d0293a6eb64b5fd6bba642e0b0330d99)
advances both direct SwiftPM pins and the release stack manifest:

- Container
  [`02e69edc55eb84059906d7314a25ae276911535c`](https://github.com/stephenlclarke/container/commit/02e69edc55eb84059906d7314a25ae276911535c);
- Containerization
  [`6aa6e803539c59ce754c55628e5417356216b297`](https://github.com/stephenlclarke/containerization/commit/6aa6e803539c59ce754c55628e5417356216b297).

Those tips contain the indexed EXT4 sync, full fork handoffs, the
service-independent formula smoke, and the retained-template workflow fix.

## Validation

```console
swift package resolve
make stack-consistency coverage-tools-test check
make coverage-check
```

Observed on Apple silicon macOS:

- SwiftPM resolved the exact Container and Containerization revisions.
- Stack consistency passed with the direct and transitive runtime pins
  aligned.
- Release and CI tooling passed 156 release tests, 14 CI tests, 4 coverage
  tests, and shell policy fixtures.
- Compose passed 1,117 Swift tests in 26 suites.
- Swift coverage was 91.39%; Go coverage was 90.06%.
- Container passed 1,134 normal and 1,135 instrumented tests in 131 suites.
- Containerization passed 647 tests in 85 suites with coverage reporting.
- The active stable Container and Compose Homebrew formula tests passed.

The automatic Current workflow provides the final exact-documentation-commit
runtime, Docker Compose 5.3.1 parity, SonarQube, package, tap, and direct
typed-command VHS evidence.

## Commit tracking

- Containerization final tip:
  `6aa6e803539c59ce754c55628e5417356216b297`.
- Container final tip:
  `02e69edc55eb84059906d7314a25ae276911535c`.
- Compose source pin:
  `3decbde6d0293a6eb64b5fd6bba642e0b0330d99`.
