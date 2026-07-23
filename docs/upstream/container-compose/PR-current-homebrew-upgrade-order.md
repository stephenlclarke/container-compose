# Pull request: make Current Homebrew upgrades monotonic

<!-- markdownlint-disable MD013 -->

## Summary

- Generate the Current Homebrew version from the monotonically increasing
  Prebuilt Binaries workflow run number followed by the short source SHA.
- Validate both inputs in a focused release helper rather than embedding
  unvalidated version construction in workflow shell.
- Add executable unit coverage and release-policy assertions.
- Document why Current uses publication order for upgrades and the SHA for
  immutable source traceability.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Current publication for `0e7d6e7386a068fb44f62d306127613814404aa5`
correctly advanced the mutable release and atomically updated both Homebrew
formulae, but an installed `current.12fe9e322366` pair did not upgrade to
`current.0e7d6e7386a0`. Git SHAs identify content; they do not provide release
ordering. Homebrew therefore treated the newer pair as not newer and left the
installed runtime and plugin stale.

The Prebuilt Binaries workflow run number is monotonically increasing for every
publication attempt in this repository. Rendering
`current.<run-number>.<short-sha>` gives Homebrew a stable ordering component
while retaining the exact source identity that operators use for provenance.
The same generated version still flows into both formula renderers and one
signed atomic tap commit.

## Commit and code map

Signed commit `057089c8957d609de3c8b16ad8d858e4088f666d`
(`fix(release): make Current Homebrew upgrades monotonic`) is the focused
implementation:

- `Tools/release/current-formula-version.py` validates a positive decimal
  workflow run number and canonical 40-character lowercase commit SHA, then
  emits the ordered Current version.
- `Tools/release/test_current_formula_version.py` covers the helper API and CLI
  success and failure paths.
- `.github/workflows/prebuilt-binaries.yml` passes `GITHUB_RUN_NUMBER` and
  `PUBLISH_SHA` to the helper for the Current lane only. Stable semantic
  versions are unchanged.
- `Tools/release/test_container_stack_release.py` rejects a return to
  SHA-only Current formula versions.
- `BUILD.md` documents the upgrade-order invariant for operators.

No Compose runtime or Apple fork code changes. Asset names, checksums,
attestations, the mutable `current` tag, exact-main authority, signed atomic tap
updates, and stable semantic versions remain unchanged.

## Testing

- [x] Focused helper and release-policy tests: 65 passed.
- [x] Homebrew `Version` comparison:
  `current.847.000000000000 > current.12fe9e322366`.
- [x] `actionlint` for the package workflow.
- [x] Markdown lint for the updated build documentation.
- [x] Python compile validation and `git diff --check`.
- [ ] Complete matched-stack local release gate.
- [ ] Exact-main CI, CodeQL, Quality, Documentation, and SonarQube.
- [ ] Refreshed Current assets, checksums, attestations, and rendered GIF.
- [ ] Signed atomic Homebrew formula pair.
- [ ] Ordinary `brew upgrade` followed by runtime and volume smoke.

The source runtime remains covered by the immediately preceding matched-stack
gate: Builder unit tests with 44.4% Go statement coverage; 646
Containerization unit tests and 175 of 177 integration tests with the two
expected virtio GPU skips; 1,135 Container unit tests and 381 integration tests
with 51.58% combined line coverage; 1,114 Compose Swift tests with 91.39% line
coverage and 90.06% Go statement coverage; 25 of 25 live Compose scenarios; and
56 of 56 strict Docker Compose V2 parity contracts against Docker Compose
5.3.1.

## Compatibility and risk

The change affects only mutable Current formula metadata. Stable formula
versions remain semantic versions, and the short SHA remains visible in the
Current version and immutable asset names. `GITHUB_RUN_NUMBER` is scoped to the
package workflow and increases for later runs; a rerun retains the same source
and run number, preserving idempotence.

The publication transaction is unchanged: candidate assets are staged first,
both formulae are rendered and signed together, the mutable tag moves only
after the tap update, and stale-main candidates are rejected.

## container-compose Checks

- [x] `BUILD.md` and `docs/upstream/` are current.
- [x] This change is focused on one release defect.
- [x] Runtime and cross-repository release review notes are attached.
- [x] Commit and proposed pull-request title use Conventional Commits.
- [x] The commit includes a user-facing `Release-Note:` trailer.
- [x] The implementation commit is signed.
- [x] No credentials, tokens, keys, personal data, or registry details are
  included.
