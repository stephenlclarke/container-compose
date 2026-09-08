# Issue 593: replace Nextflow with a recoverable native build

## Problem

The Container-family build duplicated SwiftPM and Go dependency work inside a
separate Nextflow and Java runtime. Recovery depended on orchestration-session
state rather than on the exact source, toolchain, dependencies, and artifacts
that had already built successfully. That made failures difficult to resume,
made stale state harder to diagnose, and added bootstrap work to an otherwise
native build.

## Scope

- Use Make only to declare the small repository dependency graph.
- Leave compilation to SwiftPM and Go, retaining their native scratch caches.
- Publish an atomic, authenticated pin after each successful repository build.
- Make every downstream repository discover and consume the verified upstream
  pins automatically.
- Invalidate only the changed repository and its transitive consumers.
- Serialize writers and publish one exact final stack bundle under the lock.
- Keep signing, virtual machines, CodeQL, documentation, parity, and release
  packaging outside the ordinary source-build path.
- Retain exact-input checkpoints and durable logs for release-only validation.

## Acceptance evidence

- A forced Container failure leaves the independent upstream pins intact; the
  next invocation reuses them and resumes only the failed Container stage.
- Advancing Containerization rebuilds Containerization and Container without
  rebuilding the independent Engine API stage.
- Dirty or changed source, remote identity, toolchain contract, dependency
  receipt, artifact, or pin content fails verification before reuse.
- Pins and the final bundle are written atomically and reject indirect paths,
  duplicate records, malformed metadata, and concurrent stage execution.
- Stable release validation retains candidate-keyed exact-input checkpoints
  and resumes at the first missing or invalid release stage.
- Focused recovery, release-authority, workflow-policy, and benchmark tests
  pass without running a product-wide build cycle.
