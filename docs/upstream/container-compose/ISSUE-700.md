# Pin the Xcode 27 coverage-compatible runtime stack

## Problem

The unattended 0.15.2 promotion exposed an inherited Containerization
coverage path that no longer exists with the split test bundles emitted by
Xcode 27 and Swift 6.4. The stable controller correctly stopped rather than
publishing incomplete quality evidence.

Containerization issue
[#101](https://github.com/stephenlclarke/containerization/issues/101) and pull
request
[#102](https://github.com/stephenlclarke/containerization/pull/102) repair the
coverage exporter at reviewed merge
`51bf8a10e2036861f87ccdf2fd881a8726c534d2`. Container issue
[#281](https://github.com/stephenlclarke/container/issues/281) and pull request
[#282](https://github.com/stephenlclarke/container/pull/282) pin that runtime
at reviewed merge `2b4255631681e8e41cdc243f8f61c40348e18cc1`.

## Scope

- Pin both exact reviewed runtime merges in the manifest, lockfile, and release
  authority.
- Refresh the reviewed fork classifications, upstream audit, and README
  divergence metrics.
- Preserve Compose and runtime semantics unchanged.
- Publish and verify a new exact-main Current candidate before resuming the
  unattended 0.15.2 stable release.

## Acceptance evidence

- Stack consistency, source preflight, fork classification, static lint,
  Markdown, and JSON gates pass.
- Required exact-head checks and automated review pass before merge.
- The new exact-main Current artifacts are signed, notarized, attested, and
  represented by a matched Homebrew formula pair.
- The unattended stable controller passes isolated Containerization coverage
  and completes 0.15.2 publication.

## Compatibility

This is a release-engineering and dependency-provenance correction. It does not
change claimed Docker Compose behaviour or stock Apple compatibility.

Tracking issue: [#700](https://github.com/stephenlclarke/container-compose/issues/700).
