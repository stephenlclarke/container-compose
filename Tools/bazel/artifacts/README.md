# Compiled ArgumentParser layer

This first dependency layer packages Apple's `swift-argument-parser` repository
as one releasable unit. The internal `ArgumentParserToolInfo` and
`ArgumentParser` modules remain separate Bazel targets; the archive carries
both `.swiftmodule` files, documentation, static libraries, upstream license,
and package metadata. Its manifest fixes the upstream source commit, producer
commit, Apple silicon/macOS compiler and SDK, Bazel recipe, configuration, and
every member hash. The producer's Q qualification and source-unit results live
in a separate release evidence asset bound to the archive SHA.

To produce from the qualified Container Q checkout, use
`argument_parser.py produce` with its exact `--container-root`, `--source`,
`--qualification-dir`, both `--test-events` paths, and a fresh absolute
`--output` directory. The producer verifies the Q checkout is clean and the
acceptance, source-input, and targeted test BEP records match the commit.
`write-lock` binds the resulting archive and evidence sidecar to the Compose
package pin. `publish --receipt` stages both assets as a draft prerelease,
verifies the remote tag and downloaded bytes, then publishes. Publication is
reserved for an independently reviewed, qualified layer.

The source-built profile is the default and remains the hosted quality path.
Run `Tools/bazel/run.sh build --config=release
--config=prebuilt-argument-parser //:compose` to consume the published layer.
On its first use, the launcher verifies the GitHub release tag, archive, and
qualification evidence, then retains a receipt and exact bytes. Later builds
reuse that cache offline after checking its hashes against the lock. For a
local producer proof before publication, set
`COMPOSE_ARGUMENT_PARSER_LAYER_MIRROR` to the exact archived `.tar.gz` file;
that explicit development path does not claim GitHub release provenance. The
launcher rejects different compilers, SDKs, configurations, and a mismatched
mirror. Bazel imports the package under the original SwiftPM repository labels
with no source fallback. The Container repository does not enable GitHub
immutable releases; the lock's content hashes and recorded tag commit provide
consumer integrity, while offline reuse retains the original verified receipt.

The generic `release_asset.py fetch --lock LOCK.json --destination FRESH_DIR`
transport also handles signed Container runtime, guest, or builder assets.
Its lock uses `schema`, `repository`, `tag`, `targetCommit`, `asset`, and
`sha256`; it records a `fetch-receipt.json` after verifying the published tag,
unique asset, downloaded bytes, and unchanged release identity.

For Container releases after the explicit `6fe80db1` legacy source, the qualified runtime sidecar must also carry its native dependency chain. Admission checks the four published dependency releases, release and coverage build identities, original executable hashes, signed distribution hashes, and benchmark asset links. Coverage metadata actions are distinguished from dependency compilation. Any admitted verifier-only recipe transition retains its exact old/new hashes and policy identity in both release and coverage evidence; a missing chain or inconsistent provenance fails admission. This validation does not rebuild the dependencies or regenerate historical benchmarks.

## Package-group layers

`foundation.py` applies the same binary import contract to four package
groups: `foundation`, `containerization`, `engine-api`, and `container-sdk`.
Each group has separate enhanced and stock locks under `layer-locks/`. The
foundation contains the reached third-party Swift and C packages, excluding
ArgumentParser, which stays as the already published lower layer. The three
SDK groups each contain their corresponding pinned Stephen-owned source
package. Each upper manifest records exact lower archive and evidence hashes;
the original SwiftPM package labels, resource edges, headers, module maps,
licenses, linker flags, and compiled interfaces remain in the sealed archive.

Produce in dependency order. `foundation.py produce --root ROOT --group
foundation --profile enhanced --lower-lock
ROOT/Tools/bazel/artifacts/argument-parser.lock.json --output FRESH_ABSOLUTE_DIR`
builds the configured production Compose closure with the published lower
ArgumentParser layer, then seals only reached foundation outputs. Use `stock`
for its separate lock. For `containerization` and `engine-api`, the producer
uses a published foundation binary; `container-sdk` requires both published
SDK lower binaries. Building the configured Compose closure preserves its
current minimum-macOS transitions and reuses Bazel's action cache; it may
still visit already-built upper targets. A dirty checkout needs the explicit
`--development-proof` flag and cannot be published.

The consumer can reuse original published lower archives across a Container-only
pin change while Containerization remains at `6db16197`, or across the exact
Container `db240b6c` and Containerization `6db16197` pair. For the Container-only
case, the selected 40-character pin must occur once in both package files, and
`Package.resolved` must contain exactly one `originHash` equal to the SHA-256 of
the actual `Package.swift`. The verifier normalizes that pin and origin back to
the published baseline, then requires the complete manifest and resolved lock to
match the historical hashes. Other dependency or recipe changes are rejected.
These pin transitions permit the unchanged enhanced foundation, released
Containerization, Engine API, and four stock groups; enhanced Container SDK
needs a newly qualified archive. All other source, recipe, lower-layer and
toolchain checks remain intact. A future pin pair needs a new proof or a
rebuild.

On a clean producer checkpoint, run the two source-mode optimized CLI targets
with the appropriate published lower configs, then use
`layer_release.py write-evidence` with the producer receipt and that admitted
test invocation. `layer_release.py write-lock` emits a compact lock outside
the checkout. After review, `layer_release.py publish` uses the shared
`release_asset.publish_assets` transport: a new draft prerelease is checked
against the exact owning-repository commit and both downloaded asset hashes
before publication. For foundation, the target is the clean Compose producer
commit; for each SDK group, it is that package's pinned source commit. The
Compose producer commit and test/build evidence remain in the separate
qualification sidecar. A pre-pushed release tag is allowed only when it
already points to that exact target; assets are never overwritten.

The normal consumer selects `--config=prebuilt-foundation`,
`--config=prebuilt-containerization`, `--config=prebuilt-engine-api`, or
`--config=prebuilt-container-sdk` together with the exact release/profile
configuration. Each upper config selects its required lower binaries. On the
first use, the launcher verifies the published archive and evidence sidecar;
later uses rehash the exact lock-keyed local cache without network. A local
mirror is an explicit development proof only. The compiled groups are
unavailable on a different Swift compiler, SDK, platform, source pin, recipe,
or lower-layer digest. Hosted source analysis continues to compile sources.

## Qualified Container runtime release

`q_runtime_release.py prepare` is the maintained metadata producer for a
qualified Container runtime candidate. Pass explicit absolute
`--container-root`, `--qualification-dir`, Compose `--root`, and a fresh
`--output`. It derives the source commit from the clean Container checkout,
checks the complete maintained qualification stage inventory and retained
receipts, replays both compiled-consumer receipts with the Container native
verifiers, and records the reused native locks. A missing native-layer cache
may be populated through its existing authenticated release transport. It
packages the signed runtime, measured executables, portable benchmark results
and provenance sidecar; it does not build or run the Container runtime. Supply
`--scratch /Volumes/SSD/cf/bazel/tmp` (the default) for re-derivation and
publication downloads; the command verifies that this path is on the enrolled
external SSD.

Review `preparation.json` and its exact asset hashes before invoking the
separate `publish` action. Publication rechecks the source, all retained
qualification hashes, native receipt graph, lower-layer release identities,
and the sidecar through `q_assets.validate(..., qualified_source=SOURCE)`;
the consumer's selected `Q` constant and locks remain unchanged until the
release assets exist. The shared release transport verifies the draft bytes
and exact tag target before exposing them. Publication resumes only under its
exact retained source, tag, owner, and asset-byte journal; its bounded upload
scratch stays on the enrolled SSD. After publication,
`q_runtime_release.py verify` downloads each locked asset and revalidates the
provenance, performance ZIP, and native-chain crosslinks. The retained
preparation receipt records `releaseAuthority: false`; preparation alone is
not release approval.

The corresponding `bazel-q-runtime-release-prepare`,
`bazel-q-runtime-release-publish`, and `bazel-q-runtime-release-verify` Make
targets pass the explicit SSD scratch path. Keep the private output directory
between steps so the preparation receipt and resumable publication journal
remain available for review and recovery.
