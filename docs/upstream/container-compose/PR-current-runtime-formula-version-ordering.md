# Pull request: version the Current Homebrew pair monotonically

<!-- markdownlint-disable MD013 -->

## Summary

- Reuse the validated Current formula version for the matched runtime formula.
- Keep stable semantic runtime versions unchanged.
- Add release-policy regression assertions that reject the SHA-only runtime
  version.
- Clarify that both Current formulae share one atomic version identity.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Prebuilt Binaries run `30004659566` published a correct seven-asset Current
release for `bc8399014f878ac769360668e6df73d9c23a0731`, but tap commit
`2aa3bc4fcf92fd1f3e2f42e3e45f54f53023904a` exposed different ordering
policies:

```text
container-compose-current: current.849.bc8399014f87
container-current:         current.bc8399014f87
```

The Compose version is ordered by package-workflow run number before source
identity. The runtime version is ordered only by source identity, so a later
hash can sort below the installed runtime even though both formulae are
promoted atomically.

## Commit and code map

Signed commit `376ccadd5900aff24855e0872999e1d7851041ca`
(`fix(release): version Current runtime monotonically`) is the focused
implementation:

- `.github/workflows/prebuilt-binaries.yml` passes
  `steps.lane.outputs.formula_version` into the runtime package step and uses it
  for the branch/Current runtime version.
- `Tools/release/test_container_stack_release.py` requires the shared version
  flow and rejects the former SHA-only runtime assignment.

The documentation commit updates `BUILD.md` and adds this issue/pull-request
handoff. No Compose runtime, Apple Container fork, Containerization fork,
stable-release, archive, checksum, or attestation behavior changes.

## Testing

- [x] Focused Current-version and stack-release policy tests: 66 passed.
- [x] Complete release-tool suite: 154 passed.
- [x] `actionlint` for `prebuilt-binaries.yml`.
- [x] `git diff --check`.
- [ ] Complete matched-stack local release gate.
- [ ] Exact-main CI, CodeQL, Documentation, full Quality, and SonarQube.
- [ ] Automatic Current Package job and seven-asset publication.
- [ ] Matching signed tap formulae with one monotonic version.
- [ ] Ordinary Homebrew upgrade of both Current formulae.
- [ ] Installed runtime/Compose, named-volume, and typed-command VHS checks.

## Compatibility and risk

Current is the only affected lane. The runtime formula receives the same
already-validated version used by the Compose formula. Stable tag publication
continues to assign the semantic tag directly in the unchanged tag branch.

The change is deliberately release-layer-only and fail-closed: if the lane
cannot produce its Current formula version, the runtime package step cannot
render a tap update.

## container-compose Checks

- [x] `BUILD.md` and `docs/upstream/` are current.
- [x] This change is focused on one reproduced release defect.
- [x] The issue and pull-request handoffs reference the signed implementation.
- [x] Commit and proposed pull-request titles use Conventional Commits.
- [x] The implementation commit includes a user-facing `Release-Note:` trailer.
- [x] The implementation commit is signed.
- [x] No credentials, tokens, keys, personal data, or registry details are
  included.
