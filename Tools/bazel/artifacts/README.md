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
