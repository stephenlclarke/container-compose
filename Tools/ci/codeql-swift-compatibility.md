# Reviewed Swift certificate compatibility findings

This disposition retains two raw CodeQL findings. It is not a claim of zero raw alerts, a blanket dependency exclusion, or a change to cryptography. The release gate requires zero unreviewed findings, complete source extraction and zero extraction errors. All findings remain in the original uploaded SARIF.

## Exact evidence

CI run `36448673660`, source `c5285c70574a59c84650403093771ad610976473`, extracted all 139 stock and 142 enhanced inventoried production files with no extraction errors. Both profiles reported the same two `swift/weak-sensitive-data-hashing` findings in upstream [`swift-certificates` 1.20.0](https://github.com/apple/swift-certificates/tree/c8aece90ea05f9866bd392a5bf13b5cae56c0e03):

- `Sources/X509/Signature.swift:371`: RSA verification explicitly selected by
  `.sha1WithRSAEncryption`.
- `Sources/X509/Signature.swift:536`: RSA signing explicitly selected by
  `.sha1WithRSAEncryption`.

[The pinned disposition](codeql-swift-compatibility.json) records the repository, commit, complete source-file SHA-256, both lockfiles, rule, exact URI, region, fingerprints, and expected count of two. The checker verifies the actual SwiftPM checkout commit and source bytes. The hosted aggregate and local admission independently reclassify raw SARIF and verify the disposition/source receipt. Missing, duplicate, moved, changed, suppressed or additional findings, changed pins/source, extraction errors and incomplete inventories fail the gate.

## Review rationale and limits

Upstream deliberately exposes this legacy algorithm: its [`testHashFunctionMismatch_rsa_sha1WithRSAEncryption`](https://github.com/apple/swift-certificates/blob/c8aece90ea05f9866bd392a5bf13b5cae56c0e03/Tests/X509Tests/SignatureTests.swift#L502) expects RSA/SHA1 signing and verification to succeed. The algorithm choice is an explicit argument or certificate algorithm identifier; replacing its hash with SHA-256 would break the declared algorithm. The branches have existed since upstream commit `eaed0355` in January 2025, with verification delegation refactored in `133a3479` in November 2025.

The reviewed Compose production sources neither import X509 nor select `sha1WithRSAEncryption` or `Insecure.SHA1`. The transitive gRPC transport uses X509 to represent certificate data, including conversion from an already validated NIOSSL chain in `ValidatedCertificateChain.swift` and peer-certificate metadata in `HTTP2ServerTransport+Posix.swift`. The observed CodeQL traces start and finish within the certificate library; they do not demonstrate a Compose call selecting weak certificate signing or verification. This is a reviewed inherited compatibility capability, not a claim that SHA-1 is secure or that all possible library uses are unreachable. The library also offers direct signing and verifier APIs; a future consumer use must be reviewed anew.

[CodeQL's rule](https://codeql.github.com/codeql-query-help/swift/swift-weak-sensitive-data-hashing/) correctly treats certificate bytes as sensitive. Both raw findings therefore remain visible as `alert_count: 2`, with `reviewed_compatibility_count: 2` and `actionable_alert_count: 0` / `unreviewed_alert_count: 0` only for this exact reviewed pair. No GitHub alert dismissal is required or performed by this code. Sonar issue/hotspot and coverage policies are unchanged.
