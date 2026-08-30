# Issue 278: comparable-or-better same-host performance

## Problem description

Compose has functional parity evidence, but runtime lifecycle work still pays avoidable serialization and repeated preparation in the Container-family dependencies. The release stack must also pin exact mutually compatible source revisions so performance changes remain reproducible and recoverable.

## Requested outcome

- Retain Compose behavior while consuming the reviewed Containerization, builder-shim, and Container optimization stack.
- Pin immutable merged dependency revisions in the Swift package graph and release stack manifest.
- Keep generated builder protocol source paired with the immutable builder image used by Container.
- Preserve the matched before/after evidence and its environment fingerprint without attributing aggregate gains to any isolated commit.
- Continue tracking the separate Compose scaling gap where 10- and 50-service startup exceed the current Docker parity guard.
- Reuse a bounded invocation lifetime for ordinary Container API control calls
  without coupling attach or exec session disconnects to that control lifetime.
- Exercise both Compose and Container from signed release builds in the stable
  parity gate instead of allowing either binary to fall back to a debug build.
- Reject a loaded production Container launch agent before isolated timing so a
  crash loop cannot invoke Keychain, consume host resources, or contaminate the
  candidate/reference comparison.

## Acceptance evidence

- Containerization, builder-shim, and Container dependency PRs are merged and green.
- Compose package and release manifests resolve to the exact merged revisions.
- Stack-consistency checks pass with no local override.
- Focused Compose dependency, manifest, and lifecycle contract tests pass.
- Exact-head review and required GitHub checks find no remaining issue.
- The retained benchmark shows 84 of 84 operations passing in each lane with functional parity.
- Focused concurrency evidence proves 100 simultaneous control-client requests
  construct one value, session clients remain distinct, and dependency wiring
  stays lazy until a runtime operation occurs.
- The exact matched-stack client-reuse benchmark retains functional parity and
  the diagnostic 10x guard without claiming a latency improvement from mixed
  timing results.
- A quiet-host exact-release rerun records Docker/container-compose bridge-up
  medians of 0.137s/1.299s (9.46x, pass) and bridge-down medians of
  10.146s/5.803s (0.57x, pass), with raw TSV, JUnit, and fingerprints retained.

## Remaining scope

The dependency-integration and invocation-client slices are measured
contributions to issue 278, not its closure. Client reuse removes redundant XPC
connection construction and clarifies session ownership, but the seven-run
latency matrix is mixed: the 1-service startup median improves by 5.3%, while
the 10- and 50-service startup medians regress by 10.0% and 13.2%. The change
therefore makes no latency claim. Issue 278 remains open for Compose-owned
profiling, explicit shared or dedicated VM isolation, pre-warming, and the
other performance lanes in its public completion contract.

The 0.14.0 release gate initially recorded a 10.62x bridge-up result while a
loaded `container-current` apiserver was crash-looping every approximately ten
seconds. Its launchd record showed 9,592 runs, and the loop repeatedly invoked
Keychain authentication. Stopping those exact production agents and rerunning
the unchanged release artifacts on a quiet host produced the passing 9.46x
result above. This is a measurement-integrity correction, not a timing waiver
or a claim that dedicated-VM cold start is now comparable to Docker.

## Related work

This handoff records [issue 278](https://github.com/stephenlclarke/container-compose/issues/278). Its implementation dependencies are [Containerization pull request 37](https://github.com/stephenlclarke/containerization/pull/37), [builder-shim pull request 12](https://github.com/stephenlclarke/container-builder-shim/pull/12), and [Container pull request 142](https://github.com/stephenlclarke/container/pull/142). The Compose-owned client reuse is [pull request 327](https://github.com/stephenlclarke/container-compose/pull/327).

The later 0.14.0 optimization chain is listed in the
[Apple upstream review](../APPLE-UPSTREAM-REVIEW.md#0140-optimization-pull-request-provenance).
Its live 28 August 2026 audit found no submitted Apple upstream PR containing a
benchmarked Container, Containerization, builder-shim, or Compose optimization;
the stock-Apple `upstream/pr-*` branches remain unsubmitted candidates.
