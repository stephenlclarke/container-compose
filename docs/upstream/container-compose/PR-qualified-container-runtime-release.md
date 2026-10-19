# Pull Request: Produce Qualified Container Runtime Release Assets

## Summary

Adds a maintained staged producer for the five Q runtime release assets: signed runtime archive, qualified provenance sidecar, measured fork archive and manifest, and a path-free performance/parity ZIP. The producer requires complete exact-source qualification, admits the native compiled-consumer chain and unchanged lower-layer identities, and keeps preparation, publication, and remote download verification separate.

See the companion [issue handoff](ISSUE-qualified-container-runtime-release.md).

## Code Map

- `Tools/bazel/artifacts/q_runtime_release.py` implements source/evidence admission, deterministic asset preparation, re-derivation before publication and verification, and the explicit-source Compose validator call.
- `Tools/bazel/q_assets.py` accepts an optional qualified source for this staged path while preserving the existing default source lock.
- `Makefile` and `Tools/bazel/artifacts/README.md` expose and document the three operations.
- `Tools/bazel/artifacts/test_q_runtime_release.py` covers receipt and source admission, authenticated historical ZIP handling, raw comparison recomputation, public projections, and archive crosslinks.
- `Tools/bazel/artifacts/test_q_runtime_release_flow.py` exercises successful deterministic preparation, projection, re-derivation, resumable publication, exact locks, and downloaded-byte verification with only transport and native-chain boundaries injected.

The performance/parity ZIP keeps raw runtime, Docker, component, and integration measurements with matrices, semantic-review outcomes, source and toolchain identities, and historical measurement provenance. Its stock runtime fingerprint comes directly from the hash-verified historical archive; the current reused-reference qualification does not fabricate a stock fingerprint receipt. The Docker comparison preserves archived Engine 29.2.1 measurements alongside the observed Engine 29.5.2 identity.

## Validation

```console
PYTHONPATH=Tools/bazel:Tools/bazel/artifacts python3 -m unittest -q test_q_runtime_release_flow test_q_runtime_release test_q_assets
```

The focused producer suite passes 45 tests; the shared resumable release-transport suite passes 14 tests. Together they cover the successful producer flow and rejection cases for changed historical samples, ratios, tags, publications, and locks, with deterministic interruption/retry and download stubs. A standard-library line trace reached 1,198/1,493 executable lines (80.2%) in the full producer module. That whole-file figure includes native-layer orchestration and real host/GitHub boundaries that the hermetic fixture deliberately injects; the actual current-source eight-product chain was independently read-only replayed, and the transport boundary has its own focused regressions. The maintained prepare target has now completed against the immutable f86 qualification: five candidate assets were produced, including the already signed and notarized distribution archive and the unchanged measured executable archive with `releaseAuthority: false`, and the private receipt map binds the two fresh component fork manifests while retaining stock and unchanged fork identities from the authenticated historical archive. No publication or download verification is claimed; the prepared private receipt map and five assets remain subject to independent review.

## Review Boundary

Preparation may fetch exact authenticated native lower-layer assets using the existing shared transport. It does not rebuild or execute Q, and it does not publish. Publication rechecks the admitted source, qualification receipts, native chain, and prepared bytes before creating the release, using a durable private owner journal and enrolled SSD scratch for bounded temporary work. Verification downloads or resumes each asset only after authenticating the deterministic lock, then checks its digest and crosslinks. A qualified run must preserve the full Q qualification evidence as immutable input and report publication only if the post-publication downloads verify.
