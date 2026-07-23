# Pull request: publish relocatable release checksum sidecars

<!-- markdownlint-disable MD013 -->

## Summary

- Add one small Compose release helper that hashes an archive and records only its basename.
- Use it for the Compose plugin archive and both branch/tag runtime packaging paths.
- Prove a downloaded archive and sidecar remain verifiable after relocation.
- Document the direct `shasum -a 256 -c` verification contract.

## Commit and code map

Signed commit `f77d57fc54b0adf07766fdaa784f8b8bbaf37e33` (`fix(release): publish relocatable checksum sidecars`) is the reviewable implementation:

- `Tools/release/write-sha256-sidecar.py` streams an asset through SHA-256 and writes `<digest>  <basename>` beside it.
- `Makefile` routes Compose plugin packaging through the shared writer.
- `.github/workflows/prebuilt-binaries.yml` normalizes the Container-produced sidecar after both branch and tag runtime package builds. This keeps the compatibility repair in Compose orchestration and avoids any Apple fork API or packaging change.
- `Tools/release/test_write_sha256_sidecar.py` covers runner-path removal and an actual relocated `shasum -a 256 -c` verification.
- `Tools/release/test_container_stack_release.py` makes all three release call sites part of the workflow policy contract.
- `BUILD.md` documents that package sidecars are relocatable and gives the verification command.

No Compose runtime behavior or Apple fork code changes. Archive names, archive bytes, SHA-256 digests, attestations, release provenance, and formula hashes remain unchanged; only the filename field in each checksum record becomes portable.

## Validation

- Focused checksum and release-policy suite: 61 tests passed.
- Complete release tools: 147 tests passed.
- CI tools: 14 tests passed.
- Coverage tools: 4 tests passed.
- `actionlint .github/workflows/prebuilt-binaries.yml` passed.
- `markdownlint BUILD.md` passed.
- `git diff --check` passed.
- `make check` passed, including publish-shell regression, stack consistency, and secret scanning.
- A real release build produced `/private/tmp/container-compose-sidecar-package.PW1r1n/container-compose-plugin-test-arm64.tar.gz`; its adjacent record contained only `container-compose-plugin-test-arm64.tar.gz`, and verification returned `container-compose-plugin-test-arm64.tar.gz: OK`.

The source runtime remains covered by the immediately preceding exact-stack gate: 1,114 Swift tests, 91.39% Swift line coverage, 90.06% Go statement coverage, 25 of 25 live runtime scenarios, and 56 of 56 strict Docker Compose V2 contracts against Docker Compose 5.3.1.

Exact-main hosted workflow, SonarQube, Current, Homebrew, checksum, attestation, and rendered-GIF evidence are post-merge gates and must identify the final documentation commit rather than this source commit alone.

## Compatibility and risk

POSIX `shasum` accepts the basename record on macOS, and existing consumers that read only the first whitespace-delimited digest remain compatible. Consumers no longer need to rewrite a runner-specific path before verification. The writer reads in bounded chunks and does not alter its input archive.

The workflow deliberately overwrites the Container package target's sidecar in the Compose release workspace. That single orchestration boundary avoids a fork modification while ensuring both release lanes publish the same portable format.

## Checklist

- [x] Reproduced against immutable Current assets
- [x] Signed Conventional source commit
- [x] Compose-layer implementation with no Apple fork change
- [x] Basename-only unit coverage
- [x] Relocated `shasum -a 256 -c` integration coverage
- [x] Release-workflow policy coverage
- [x] Real absolute-path package verification
- [x] Release, workflow, Markdown, and repository checks
- [x] Signed Conventional documentation commit
- [ ] Exact-main hosted CI and CodeQL workflows
- [ ] Exact-main SonarQube `OK` gate with zero unresolved issues
- [ ] Automatic Current packaging on the self-hosted MBP
- [ ] Published Compose and Container sidecars verify without path rewriting
- [ ] Exact-main attestations, Homebrew, and rendered-GIF verification
