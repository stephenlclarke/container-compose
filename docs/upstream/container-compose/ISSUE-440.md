# Issue 440: pin deterministic NBD integration stack for 0.14.1

## Problem

The 0.14.1 stable controller correctly refused to continue because published
Current still pins the Containerization revision that exposed two
Virtualization.framework teardown failures in the release integration suite.

The lower fix is now reviewed and merged through:

- Containerization issue
  [#69](https://github.com/stephenlclarke/containerization/issues/69) and pull
  request [#70](https://github.com/stephenlclarke/containerization/pull/70) at
  merge `818f5917819a32dac1bc233605c253b4a105e0e0`.
- Container issue
  [#197](https://github.com/stephenlclarke/container/issues/197) and pull
  request [#198](https://github.com/stephenlclarke/container/pull/198) at merge
  `ecf6da9fd029a52717a574c4aab3ed5257bbeea2`.

Compose must publish those two immutable revisions together as Current before
stable 0.14.1 validation can resume.

## Required work

- Update the direct Container and Containerization pins in the Swift manifest
  and lockfile.
- Update the release stack manifest to the same exact revisions.
- Refresh current support-fork snapshot and classification evidence.
- Run only focused stack-consistency, dependency-resolution, documentation,
  and source checks before hosted validation.
- Publish the reviewed merge as Current, then resume the checkpointed stable
  controller.

## Acceptance boundary

The issue is complete when the Swift manifest, lockfile, and release stack
manifest agree on both reviewed support-fork heads; focused checks and
exact-head review pass; and a green Current package identifies the same Compose
commit and immutable stack.

Related issue:
[#440](https://github.com/stephenlclarke/container-compose/issues/440).
