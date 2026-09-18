# Native recoverable Container Compose build workflow

## Feature or enhancement request details

The operator requested a Bazel-owned build/test workflow shared with devcontainer: eliminate duplicate work, retain evidence for recovery, keep disposable files on the external SSD and long-lived assets internally, and ultimately publish qualified stable releases. The legacy build/test/release entry points remain until the complete native graph and acceptance gates replace them.

## Compose compatibility impact

Internal implementation improvement. Package.swift and the existing stock/enhanced lockfiles remain the product contract. No Docker parity scope, runtime API visibility, dependency pin or release gate is relaxed.

## Acceptance

Coverage must include actual native CLI execution without silently relabelling it as unit-only proof. The additive `unit-cli` inventory requires all existing unit targets plus the 31-case CLI component suite, with every native CLI invocation emitting a private nonempty LLVM profile. Two cases test Python process cleanup and do not launch Compose. The command-to-plan tests assert guest argument boundaries, service/replica selection, lifecycle ordering, file paths and option values through the executable, not just help output. Unit-only evidence stays distinct; exact inventory identity is required by the quality gate. Host/guest integration remains separately unqualified.

Provider-neutral external config/secret staging tests were also excluded from stock because they shared a file with enhanced concrete-store tests. Separating those preserves the original assertions, admits the neutral methods in both profiles and adds failed-store/no-private-file and dry-run no-access checks without advertising a new stock runtime capability.

Native Swift and Go compilation, all unit/integration/parity suites, meaningful coverage, explicit storage and resource ownership, unchanged-input cache reuse, recoverable signed packaging/publication and current docs must pass before production cutover. Reference parity uses downloaded releases, never rebuilt substitutes. Quiet paired benchmark evidence and installation-first demos remain required.

See [the implementation guide](guides/BAZEL.md) and [the PR handoff](PR-708.md) for current evidence and incomplete gates. Owner: this active build migration; terminal condition: reviewed complete workflow merge and qualified stable publication, followed by branch/worktree cleanup.

The stock coverage shortfall also included runtime-neutral copy/export/commit/port assertions trapped in an enhanced-only source file. The current test separation preserves all original bodies, enables 34 methods in both profiles and adds provider-neutral commit failure/cleanup probes. Coverage acceptance remains 90%; expanding test inventory is not itself proof of meeting it. The guide records measured runs and the remaining provider-specific boundary.

CLI coverage also exposed a product defect: guest `run`/`exec` help and option names could be consumed by Compose's help dispatcher or argument parser. The candidate now protects the guest argument boundary and tests through the actual root parser. The original twelve-case native CLI scope is retained within the expanded suite. The downloaded Docker Compose 5.3.1 reference provides the no-runtime missing-file/error-phase comparison. This does not establish full runtime parity or close the remaining coverage gate.

Security qualification also includes normalizer dependency alert 28, [GHSA-8wmf-6v46-5gfg](https://github.com/advisories/GHSA-8wmf-6v46-5gfg). The candidate updates the affected OpenTelemetry modules to 1.45.0 with matching native dependency notices and a red/green diagnostic-redaction regression. This remains a draft-branch fix, not default-branch alert closure or a published security release.

Packaging also lacked the full upstream root licence texts for the BoringSSL revisions identified in Swift Crypto and Swift NIO SSL's vendoring metadata. The candidate now binds both distinct texts to exact reviewed vendor and containing-package revisions, rejects stale inputs, and verifies their presence in both real optimized package profiles. This resolves that identified omission without claiming complete nested-vendor audit or distribution readiness; the [notice evidence](guides/BAZEL.md#embedded-boringssl-texts) records the remaining boundary.

The metadata collector also previously omitted licence files below package roots. It now retains `Sources/` notices and requires the five identified nested paths for libarchive, llhttp and Swift Protobuf's source vendors before assembling either profile. Missing-text regression and actual archive checks cover this correction. Three reviewed source attributions additionally cover the WIDE Project SHA1 header, uSHET and LibYAML with exact provenance and byte hashes; this is not a substitute for the remaining comprehensive dependency/file-header audit.
