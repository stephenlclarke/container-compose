# Stable release from qualified Bazel artifacts

The enhanced release path completes an existing exact-source local qualification. It preserves the measured signed executable bytes and consumes the published matched Container runtime unchanged. The product source and the release-tooling commit are separately recorded; this authority does not claim a legacy hosted Stable Release Gate result.

## Inputs and evidence

Qualification must pass every preparation stage, runtime test, Compose parity case, current-candidate benchmark and host-restoration check. An old benchmark reference is reused only after its released bytes and workload/host provenance are admitted. A previous failed attempt remains failed. Reusing authenticated preparation stages does not reuse an unsuccessful live result.

The finalizer admits the current qualification, independently reviewed notices and source availability, and exact compiled SDK chain. Only stable version/lane/branch metadata changes; legal sidecars are added. Executable bytes and modes remain unchanged. The final ZIP and Homebrew TAR have the same payload tree. The final ZIP receives its own accepted Apple notarization; the measured candidate receipt is retained separately.

Publish the source companion, license notices, benchmark/parity evidence, qualified dependency provenance, finalization provenance and notarization proof with the binaries. Freeze the complete asset inventory before exposing an immutable prerelease. Source companions are separate release assets, so normal package installation does not install full dependency source trees.

## Ordered release

1. Re-admit qualification, legal closure, exact signed payloads, frozen formula files and all controller inputs.
2. Create and verify a signed semantic tag pointing to the qualified product source.
3. Publish the complete immutable nonlatest prerelease, then authenticate actual GitHub downloads and executable signatures.
4. Install the exact Container and Compose formula pair through a temporary owned tap. Run both real formula tests, verify payload hashes and source/version identity, then restore the existing four formula installations, links and service registrations.
5. Commit and push the exact tested public formula pair together in one tap commit.
6. Recheck installation/restoration proof, tap state, signed tag and immutable inventory, then promote the same release ID to stable/latest.

The runtime formula also downloads a frozen text-only notices resource and installs the license, third-party notices and source-availability links with the runtime. Its distribution version allows Homebrew to upgrade from an older keg. The unchanged runtime executable reports its original embedded product version and qualified source. Both identities are recorded and checked independently.

## Commands

`make bazel-compose-stable-tools-test` runs focused offline tests of archive preservation, notarization recovery, release ordering, input authentication and installation restoration. It does not publish or claim a real installation pass.

`make bazel-compose-stable-finalize` requires explicit qualified source, qualification directory, stable version, reviewed closure and its digest, output directory and notarization profile. Use a clean pinned tooling checkout. The finalizer records durable submission intent and resumes an existing notary submission rather than submitting it again.

`make bazel-compose-stable-publish` requires a frozen public plan and a hash-bound private execution manifest. Its durable phase journal revalidates completed work when resumed. Uncertain installation or tap operations require authenticated reconciliation; missing receipts never imply success. Private execution paths and credentials are excluded from public provenance.

## Validation status

The installation adapter has focused admission, same-version replacement and failure-restoration regressions. Production completion additionally requires the real downloaded installation receipt with `passed-restored`, equal before/after inventories, exact tested formula hashes and verified public tap commit. No mock test, prerelease publication or archive-only receipt substitutes for that proof.

Tracked by [issue 711](https://github.com/stephenlclarke/container-compose/issues/711). Historical qualification notes remain in the [Bazel guide](BAZEL.md).

Detailed contracts: [finalizer](../compose-stable-finalizer.md) and [production controller](../compose-stable-controller.md).
