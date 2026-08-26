# Issue 278: comparable-or-better same-host performance

## Problem description

Compose has functional parity evidence, but runtime lifecycle work still pays avoidable serialization and repeated preparation in the Container-family dependencies. The release stack must also pin exact mutually compatible source revisions so performance changes remain reproducible and recoverable.

## Requested outcome

- Retain Compose behavior while consuming the reviewed Containerization, builder-shim, and Container optimization stack.
- Pin immutable merged dependency revisions in the Swift package graph and release stack manifest.
- Keep generated builder protocol source paired with the immutable builder image used by Container.
- Preserve the matched before/after evidence and its environment fingerprint without attributing aggregate gains to any isolated commit.
- Continue tracking the separate Compose scaling gap where 10- and 50-service startup exceed the current Docker parity guard.

## Acceptance evidence

- Containerization, builder-shim, and Container dependency PRs are merged and green.
- Compose package and release manifests resolve to the exact merged revisions.
- Stack-consistency checks pass with no local override.
- Focused Compose dependency, manifest, and lifecycle contract tests pass.
- Exact-head review and required GitHub checks find no remaining issue.
- The retained benchmark shows 84 of 84 operations passing in each lane with functional parity.

## Remaining scope

This dependency-integration slice is one measured contribution to issue 278, not its closure. The existing Compose startup scaling guard still exceeds Docker by more than 10x at 10 and 50 services, so issue 278 remains open for Compose-owned profiling and scaling work after this exact optimized runtime stack lands.

## Related work

This handoff records [issue 278](https://github.com/stephenlclarke/container-compose/issues/278). Its implementation dependencies are [Containerization pull request 37](https://github.com/stephenlclarke/containerization/pull/37), [builder-shim pull request 12](https://github.com/stephenlclarke/container-builder-shim/pull/12), and [Container pull request 142](https://github.com/stephenlclarke/container/pull/142).
