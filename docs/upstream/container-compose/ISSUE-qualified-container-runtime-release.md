# Produce a Qualified Container Runtime Release from Complete Evidence

## Problem

The Compose repository can validate downloaded Q runtime assets, but it has no maintained producer that turns a completed, exact-source Container qualification into the runtime release, provenance sidecar, measured executable pair, and useful performance record. Reconstructing these products from handoff files risks accepting stale qualification results, mismatched native dependencies, edited measurements, or private host paths.

## Expected Behavior

- Prepare only from a clean Container source checkpoint and its complete, passed qualification evidence, including accepted notary, install restoration, full integration and coverage, hosted quality, component review, Docker admission, and the authenticated historical benchmark archive.
- Admit the actual native compiled-consumer graph and unchanged published lower-layer release identities. Preparation may fetch authenticated lower-layer assets but never rebuilds or runs the runtime.
- Produce five release assets: the signed runtime archive, `qualified-container-assets.json`, measured fork archive and manifest, and a path-free performance/parity ZIP containing raw samples, matrices, semantic review, source/toolchain identities, historical stock fingerprint, and explicit historical-versus-current Docker identity.
- Keep preparation, publication, and download verification as separate operations. Re-admit source, qualification, native graph, and asset bytes before publication; fetch and verify every published asset afterward.
- Keep global Q source locks unchanged while a new qualified source is being prepared; the producer passes that explicitly admitted source to Compose's existing validator.

## Ownership and Limits

This producer belongs in Compose's maintained `Tools/bazel/artifacts` workflow. It consumes Q qualification evidence and published Q native-layer receipts; it does not qualify, build, sign, notarize, install, or alter Q. Public performance data must not include machine-local paths, logs, credentials, or invented contemporaneous claims for historical Apple and Docker samples.

## Acceptance Criteria

- [x] Maintained `prepare`, `publish`, and `verify` entrypoints are documented and exposed through Make.
- [x] Preparation binds exact clean source, closed qualification receipts, native compiled-consumer provenance, and unchanged guest/builder locks.
- [x] Public benchmark projection retains raw measurements and provenance, the authenticated historical stock fingerprint, and the admitted Docker server-version transition without private paths.
- [x] Focused deterministic tests exercise receipt admission, projection, archive integrity, source mismatch, and altered comparison rejection.
- [ ] Complete current-source qualification finishes and its immutable evidence passes producer admission.
- [ ] The prepared assets and private source receipt map receive independent review.
- [ ] Publication occurs only after review, and the published assets pass download verification.

## Current Status

The maintained producer and focused unit tests are present. The unit suite passes 57 tests. No current-source producer run, GitHub release publication, or download verification is claimed here; those remain dependent on the complete current Q qualification and review.
