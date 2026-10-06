# Stable Compose archive adapter

This external patch stages a stable archive from a completed enhanced Compose qualification. It performs no rebuild, source edit, Git mutation, publication, Homebrew installation, or promotion. Fixture tests execute no product binaries, signing tools or notary/network commands.

## API

`stage(evidence, output, source, tool_commit, version, closure, closure_sha, *, admit, run=invoke) -> stage_receipt`

Production `admit` is the current pinned `Tools/bazel/compose_release.py:admit`; it must authenticate completed qualification. `output` is a fresh canonical absolute directory; repeat calls authenticate the same request and both retained archives. `source` is qualified product source, while `tool_commit` identifies the clean admission-tool checkout. The helper and admission-library checksums are retained separately. The only existing file changed is `resources/build-info.json`, and only its version, lane (`stable`), and branch (the semantic tag) fields change. All executable and other file bytes and file modes are preserved. Two Mach-O executables receive signature verification; both Linux ELF initializers receive hash/mode/format validation. CLI verification removes `CONTAINER_COMPOSE_BUILD_INFO` and checks version, source, lane, branch, build type and dependency pins.

Outputs: `request.json`, `stage.json`, `compose/`, `compose-stable.zip`, and `container-compose-plugin-release-arm64.tar.gz`. Both archives contain the same `compose/` file tree. The TAR is the conventional Homebrew installation asset; the ZIP is the notary submission artifact. No notary receipt is added to the finalized tree.

`notarize(output, profile, *, run=invoke) -> authority_receipt`

This explicitly invokes Apple's notary service on the final ZIP. A durable intent precedes submission. The returned submission ID is recorded before waiting; subsequent calls resume that ID. Accepted results are reused without submission. An interrupted/uncertain submit lacking an ID fails closed for operator reconciliation. Rejected results are never automatically resubmitted. Outputs: `notary.json` and `authority.json`.

The authority binds source/tool identity, qualification, finalizer/admission checksums, legal closure, ZIP/TAR hashes and accepted notary ID. It explicitly records `publicationAuthorized=false`, `signedTagVerified=false`, and `installationAndRestorationPending=true`. The root release executor must verify semantic tag authority, download exact published bytes, complete the matched runtime/Compose installation and restoration transaction, and promote only after those pass. This receipt does not impersonate the legacy Stable Release Gate.

## Legal closure contract

Legal closure is mandatory for stable staging; absent/incomplete input fails before creating output or invoking any command. Supply the independently reviewed manifest and its SHA-256 explicitly. The helper validates bindings; it does not infer legal completeness from an inventory or perform legal review.

Manifest fields: `schemaVersion=1`, `scope="reviewed-compose-legal-closure"`, `closureComplete=true`, nonempty `reviewer`, `reviewEvidence` naming one listed file, and a nonempty `files` map. `files` keys are safe single-component filenames; values are exact `{sha256, bytes}`. Files are read beside the manifest and copied to `resources/legal/`; the manifest becomes `resources/legal/closure.json` (reserved name).

`bindings` must be exactly:

- `sourceCommit`: qualified source.
- `runtimeProfile`: `enhanced`.
- `dependencyLockSHA256`: admitted `unsignedCandidate.receipt.dependencyLockSHA256`.
- `dependencyNoticesSHA256`: admitted `noticeInventorySHA256`.
- `compiledSdkChain`: the complete admitted SDK chain object.
- `containerSource`, `containerRef`, `containerizationSource`, `containerizationRef`: exact qualified build-info values.

Original candidate receipts, their incomplete-closure flags, and qualified-layer provenance remain unchanged. New reviewed closure is a separate hash-bound release admission.

## CLI

Run with a clean pinned tool checkout after qualification completes:

```sh
python3 Tools/release/finalize_qualified_compose.py \
  --checkout "$tool_checkout" --tool-commit "$tool_sha" \
  --source-commit "$qualified_sha" --evidence "$qualification" \
  --output "$fresh_output" --version "$semantic_tag" \
  --legal-closure "$reviewed_manifest" \
  --legal-closure-sha256 "$reviewed_manifest_sha"
```

Add `--notary-profile "$profile"` only when the root executor is ready to notarize. Repeating the identical arguments authenticates retained staging and reuses/resumes durable notary state.

## Validation

The focused suite uses injected admission and command fixtures on SSD. It covers exact metadata-only mutation, every legal binding, absent/incomplete closure, altered legal/qualified assets, source/profile/version mismatch, signature failure, retained archive/request tampering, accepted-submission reuse, interrupted wait recovery, uncertain submission rejection, and unsafe archive entries. Real signature, CLI and notarization execution remain for the root executor.

## External source companion

The reviewed legal manifest may specify `externalSourceCompanion={asset:'compose-source-companion.tar.gz',sha256,bytes,url}` with the exact release URL `https://github.com/stephenlclarke/container-compose/releases/download/0.16.0/compose-source-companion.tar.gz` (version substituted from the requested semantic tag). The actual adjacent file must match hash and size. It cannot appear in `files`; it is separately published and never embedded in the notarized tree. `sourceAvailabilityNotice` identifies a listed text file containing that exact URL and SHA. Request and authority bind the companion claim; the controller requires it in the complete frozen inventory before prerelease exposure. All other listed legal files remain embedded.
