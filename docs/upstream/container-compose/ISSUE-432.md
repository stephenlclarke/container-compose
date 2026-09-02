# Issue 432: align up-menu parity with retained exit-control containers

## Problem

The stable 0.14.1 release gate reached Docker Compose parity contract 56 and exposed one stale dry-run assertion. Exit-controlled `compose up` operations intentionally stop and retain containers for later inspection and log access, while the up-menu parity harness still expected `container delete`.

Production behavior and focused orchestrator tests already enforce stop-and-retain semantics. The stale parity oracle therefore rejected correct behavior rather than finding a runtime defect.

## Required work

- Assert `container stop` for the up-menu exit-control dry-run plan.
- Reject an accidental `container delete` step in that plan.
- Run the focused up-menu parity contract against the release binary.

## Acceptance boundary

The issue is complete when the focused parity contract passes against the 0.14.1 release build and the stable release advances beyond contract 56 without weakening retained-container lifecycle semantics.

Related work: issue [`#430`](https://github.com/stephenlclarke/container-compose/issues/430) and pull request [`#431`](https://github.com/stephenlclarke/container-compose/pull/431).
