# Pull request: complete Compose named no-cache stage parity

## Summary

- Preserve compose-go `build.no_cache_filter` through normalized project JSON.
- Forward every configured stage to the generic Container build filter.
- Render Buildx-compatible `no-cache-filter` arrays for `build --print`.
- Add focused Go and Swift tests.
- Add a strict Compose-file-backed Docker Compose V2 and matching macOS
  two-build parity gate.
- Update CLI help and the current parity ledger.

Resolves
[`ISSUE-compose-build-no-cache-filter.md`](ISSUE-compose-build-no-cache-filter.md).

## Type of change

- [x] Compose Build Specification parity
- [x] Docker Compose V2 fixture
- [x] Matching macOS runtime fixture
- [x] Documentation
- [ ] Windows behavior

## Layer boundary

The Compose patch remains an adapter. It preserves the compose-go field and
uses the generic `container build --no-cache-filter` option. It does not add
runtime state or reach around the Builder abstraction.

## Commit tracking

Compose signed implementation:

- `cb66a818af15615acf44155b4aad95e06c6b4d9a`
  `feat(build): add named no-cache stage filters`
- `3d6e7e72e593e474935010f70249bce379fa9b2b`
  `chore(build): pin merged no-cache runtime`

Final runtime pin:

- Container signed feature:
  `acad796bcd9e5a6cd0fd5afe7395eb7192073bf4`
- Container signed image pin:
  `03b34f3955166229c49dd45709c7291b84c9a8a8`
- Container merged fork commit:
  `ea20b242e763eb3e64d412c3dc2bbaa69639d2f4`
- Builder-shim signed feature:
  `af599a5c9cae51d7625da57d2220bd913f60d4a1`
- Builder-shim merged fork commit:
  `f97cddf5b3aae2426a094613793c11c41b1d2e53`
- Builder image:
  `ghcr.io/stephenlclarke/container-builder-shim/builder:current-30068004175-f97cddf5b3aa`
- Builder digest:
  `sha256:d993210e3960bce33a84e061d6cb96385b43277fe94a7492fd6c60b6317d2197`

## Code map

- `Tools/compose-normalizer/main.go`: normalized field projection.
- `Sources/ComposeCore/NormalizedProjectBuild.swift`: stable model.
- `Sources/ComposeCore/ComposeOrchestratorBuildAndImages.swift`: live command
  and bake projection.
- `Sources/ComposeCore/ComposeCommandOptions.swift`: bake JSON encoding.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift`: command and bake
  assertions.
- `Tools/parity/check-compose-build-no-cache-filter.sh`: strict two-build
  cross-runtime proof.
- `Tools/parity/fixtures/build-no-cache-filter`: real Compose project.
- `STATUS.md` and `Sources/ComposePlugin/ComposeCLIHelp.swift`: current support
  statement.

## Validation

```console
make test
make coverage-check
make check
make docker-compose-build-no-cache-filter-parity
```

Results:

- Full Swift suite: 1,119 tests passed.
- Swift coverage: 91.42% (minimum 90%).
- Go normalizer coverage: 90.06% (minimum 85%).
- Docker Compose V2 5.3.1 config, bake, and two-build fixture: passed.
- Matching source runtime on this MBP, exact merged Container commit
  `ea20b242e763eb3e64d412c3dc2bbaa69639d2f4` and Builder digest,
  config/bake/two-build fixture: passed.
- ShellCheck, Markdown lint, SwiftFormat, strict SwiftLint, license,
  release-tool, and stack-consistency checks: passed.
- Exact-main hosted CI/SonarQube: pending until the signed branch is merged.
- Current prerelease and signed Homebrew pair: pending until exact-main hosted
  validation passes.

## Compatibility and risk

- Omitted and empty filters remain omitted from live options and bake JSON.
- Existing all-stage `no_cache` remains unchanged and wins in the runtime when
  both forms are present.
- The fixture uses short randomized project names so generated one-off
  container identifiers remain valid on Container.
- No Containerization or Windows-specific change is required.
