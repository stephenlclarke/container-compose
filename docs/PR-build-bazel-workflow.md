# feat(build): migrate Compose to the shared native Bazel workflow

## Motivation

Implement the operator-approved [recoverable Bazel build request](ISSUE-build-bazel-workflow.md) without another coordinator or reference rebuilds.

## Implementation

- Native Swift product targets preserve both Package.resolved profiles and Swift package-access boundaries.
- The executable links the same ComposePlugin module intended for CLI tests; no SwiftPM build subprocess is involved.
- The family launcher and evidence/cache/storage implementation are reused from devcontainer PR [83](https://github.com/stephenlclarke/devcontainer/pull/83), with every shared executable helper bound by the consumer's byte/mode lock.
- The separate opt-in Makefile avoids legacy Makefile parsing, signing discovery or runtime lifecycle operations during native graph qualification.

## Validation

The initial runtime-SPI tests pass at invocation `a86eea6f-5fa1-4f36-b766-c170920e066c`; the corrected stock CLI build passes at `d3e6a329-1279-4f88-9679-6d9fd09ace39` and the enhanced build at `a66291f4-6596-4ab3-ae61-067a837c5e13`. The preceding package-name failure is retained, not rewritten. See [BAZEL.md](guides/BAZEL.md) for measured development observations and remaining exact-head validation.

## Compatibility, parity and remaining risks

No installed binary, released asset, dependency pin, runtime service or existing release workflow changes. This is an unfinished opt-in migration: full unit/resource/scratch coverage, native Go products, retained candidate packaging, complete downloaded-release parity, quiet benchmarks, quality gates and publication recovery remain open. No stable build or full-parity claim is made. Source promotion and eventual release remain PR-only under the existing exact-head review policy.
