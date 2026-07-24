# Pull request handoff: complete macOS external build-secret parity

## Summary

- Preserve external build-secret resource names through compose-go
  normalization.
- Resolve live Apple builds through the existing secure-store SPI.
- Stage secret bytes only in invocation-private 0400 files and remove them
  immediately after the build.
- Match Docker Compose V2's external-secret config and bake projection.
- Add a strict Docker Compose V2 plus optional live macOS parity fixture.
- Mark the local Phase 5 Build Specification surface complete.

Resolves
[the external build-secret issue](ISSUE-compose-build-external-secrets.md).

## Type of change

- [x] Compose Build Specification behavior
- [x] macOS secure-store integration
- [x] Docker Compose V2 integration coverage
- [x] Security and cleanup coverage
- [x] Current parity documentation
- [ ] Apple runtime API
- [ ] Windows behavior

## Layer and upstream shape

This is intentionally Compose-owned. The generic Apple Builder already accepts
file-backed BuildKit secrets, and the Compose runtime dependency bundle already
provides `ComposeRuntimeSecretReading`. The patch adds a narrow materialization
adapter around one build invocation; it does not add a secret store to
Container, Containerization, or the Builder.

Docker Compose V2 has no local external secret backend. Its observed 5.3.1
contract is retained: `config` preserves the reference, bake output omits it,
and a required live external secret is absent. The Keychain-backed live build
is the existing documented macOS extension applied consistently to build
grants.

## Code map

- `Tools/compose-normalizer/main.go` preserves the resolved external name.
- `Sources/ComposeCore/NormalizedProjectBuild.swift` carries that non-secret
  resource identifier.
- `Sources/ComposeCore/ComposeOrchestratorBuildSecrets.swift` owns validation,
  secure-store reads, private staging, dry-run projection, and cleanup.
- `Sources/ComposeCore/ComposeOrchestratorBuildAndImages.swift` consumes the
  invocation-scoped adapter and omits external secrets from bake output.
- `Tools/parity/check-compose-build-external-secret.sh` records the Docker
  contract and drives both positive live engines.
- `Tools/parity/fixtures/build-external-secret/` contains the shared Compose
  and Dockerfile proof.
- `docs/external-resources.md`, `STATUS.md`, and CLI support metadata describe
  the current surface.

## Security properties

- Keychain bytes are never encoded into the normalized project.
- Bake JSON contains no external secret entry.
- The runtime command contains an opaque temporary path, never the Keychain
  account or secret bytes.
- Each concurrent build receives a distinct UUID directory.
- Directories are 0700 and files are 0400.
- Cleanup runs after success and failure.
- Dry-run performs no Keychain read and creates no file.
- Test fixtures contain only a public parity marker, not a credential.

## Validation

```console
cd Tools/compose-normalizer
go test ./...
cd ../..
swift test --filter ComposeNormalizerTests.normalizesSupportedBuildSecretsThroughComposeGo
swift test --filter ComposeOrchestratorTests.buildMaterializesExternalSecretsOnlyForEngineInvocation
swift test --filter ComposeOrchestratorTests.buildDryRunNeitherReadsNorWritesExternalSecrets
swift test --filter ComposeOrchestratorTests.buildReportsUnavailableExternalSecretBeforeInvokingEngine
CONTAINER_COMPOSE_LIVE=0 make docker-compose-build-external-secret-parity
make test
make coverage-check
make check
```

Current local results:

- Go normalizer suite: passed.
- Seven focused Swift tests across normalizer, live staging, dry-run, failure,
  bake omission, and malformed-source coverage: passed.
- Docker Compose V2 5.3.1 external config, bake omission, expected missing
  external secret, and positive file-backed build/run: passed.
- Matching live Apple runtime external config, bake omission, Keychain read,
  BuildKit secret mount, build, run, and cleanup: passed with the implementation
  recorded in `00ed7934e994cd654f40d3717a96d3ce57cfaa17`, Container
  `ea20b242e763eb3e64d412c3dc2bbaa69639d2f4`, Containerization
  `6aa6e803539c59ce754c55628e5417356216b297`, and Builder shim digest
  `sha256:d993210e3960bce33a84e061d6cb96385b43277fe94a7492fd6c60b6317d2197`.
- Full Swift suite: 1,124 tests in 26 suites passed.
- Coverage gate: Swift 91.46% and Go 89.88% passed.
- `make check`: 155 release tests, 14 CI tests, source checks, formatting,
  lint, security, documentation, and policy gates passed.
- Exact-head hosted gates passed for
  [`f3e7563`](https://github.com/stephenlclarke/container-compose/commit/f3e756333c1c9f03ce6b7236bfba330d8730601d):
  [CI](https://github.com/stephenlclarke/container-compose/actions/runs/30077249673),
  [Documentation](https://github.com/stephenlclarke/container-compose/actions/runs/30077249675),
  [Quality](https://github.com/stephenlclarke/container-compose/actions/runs/30077249696),
  and
  [CodeQL](https://github.com/stephenlclarke/container-compose/actions/runs/30077249723).
- The GitHub-verified merge
  [`361c271`](https://github.com/stephenlclarke/container-compose/commit/361c271d18300acf0a323a411de90fe994875149)
  passed exact-main CI and SonarQube in
  [run 30078794333](https://github.com/stephenlclarke/container-compose/actions/runs/30078794333);
  exact-main Documentation, Quality, and CodeQL also passed.
- [Current build 868](https://github.com/stephenlclarke/container-compose/releases/tag/current)
  was published by
  [release run 30079633665](https://github.com/stephenlclarke/container-compose/actions/runs/30079633665)
  after a transient GitHub transparency-log 404 was retried against the same
  immutable source. The Compose package SHA-256 is
  `234d1741086375a03a551c1bc0bee3f195e5cc5a0aeefd492b1b3aa7a735ebe5`;
  the matched runtime package SHA-256 is
  `ade8a22bbc57a5022f585bcdc7939149cf9573556f311a66367d720303d7b791`;
  both provenance attestations verified.
- Signed Homebrew tap commit
  [`e794daa`](https://github.com/stephenlclarke/homebrew-tap/commit/e794daaee745b70518597b846f675d256c0c8b76)
  atomically published the `current.868.361c271d1830` formula pair. Both
  formula tests and the strict installed Docker Compose V2 5.3.1 plus live
  Apple external-secret parity fixture passed on the release Mac.
- The published live demo GIF is 1600x720, 255.16 seconds, and 6,379 frames.
  Its source tape contains 16 typed commands with 16 Enter actions and 14
  live output waits, with no Replay or Marker commands; sampled frames show
  typed commands followed by the runtime, service, volume-reuse, and shutdown
  results.

## Commit tracking

- Compose implementation:
  [`00ed793`](https://github.com/stephenlclarke/container-compose/commit/00ed7934e994cd654f40d3717a96d3ce57cfaa17)
  (`feat(build): materialize external secrets from secure store`).
- Hosted style-gate refactor:
  [`f4fab8c`](https://github.com/stephenlclarke/container-compose/commit/f4fab8c28a85d9de8249982fdf9bec2730b771e0)
  and
  [`a408c9f`](https://github.com/stephenlclarke/container-compose/commit/a408c9f613fa4b9c017970b7af6378cfa85cce6b).
- Compose documentation: this signed handoff commit.
- Runtime forks: no code change required.
