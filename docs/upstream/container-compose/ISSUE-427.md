# Issue 427: use immutable release controls for stable preflight

## Problem

The 0.13.1 stable release gate passed, but its packaging workflow failed before any build because the fail-fast job tried to execute `Tools/release/homebrew-preflight.py` from the historical tagged source. That tool was introduced after the immutable 0.13.1 source commit, so the release could not use the current release controller to publish an older compatible tag.

Tracking issue: [`#427`](https://github.com/stephenlclarke/container-compose/issues/427).

## Required outcome

- Run fail-fast Homebrew validation with an immutable checkout of the current release-control source.
- Continue validating the exact tagged Compose source, pinned Container source, and Homebrew tap.
- Reject any regression that resolves the preflight executable from the historical product tag.
- Fail before CodeQL or packaging when the distribution configuration is invalid.

## Acceptance evidence

- A focused workflow-policy regression requires the immutable release-control checkout and its preflight path.
- The existing Homebrew preflight behavior tests pass.
- `actionlint` accepts the workflow.
- A 0.13.1 packaging retry passes fail-fast validation and reaches packaging.

## Scope

This changes release orchestration only. The historical product source, pinned stack, release assets, Homebrew configuration checks, and publication authority remain unchanged.
