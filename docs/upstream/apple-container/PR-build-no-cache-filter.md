# Pull request: add named build no-cache filters

## Summary

- Add repeatable `container build --no-cache-filter STAGE`.
- Accept comma-separated filters and reject empty stage names.
- Carry named stages through the existing generic Builder metadata key.
- Keep all-stage `--no-cache` as the higher-precedence empty value.
- Pin the exact Builder shim image that preserves the metadata value.

Closes [`ISSUE-build-no-cache-filter.md`](ISSUE-build-no-cache-filter.md).

## Type of change

- [x] Generic Container build option
- [x] Builder metadata adapter
- [x] Unit and matching-runtime integration coverage
- [ ] Compose-specific runtime state
- [ ] Windows behavior

## Apple-shaped boundary

This patch does not add a Docker Compose model to Container. It exposes a
generic Dockerfile-stage cache filter at the existing CLI/Builder abstraction
and transports it through the existing `no-cache` metadata key. The matched
shim remains responsible for the final BuildKit frontend projection.

## Commits and code map

Signed implementation commits:

- `acad796bcd9e5a6cd0fd5afe7395eb7192073bf4`
  `feat(build): add named no-cache filters`
- `03b34f3955166229c49dd45709c7291b84c9a8a8`
  `chore(build): pin no-cache filter builder shim`

Merged fork commit:

- `ea20b242e763eb3e64d412c3dc2bbaa69639d2f4`
- Fork PR: <https://github.com/stephenlclarke/container/pull/28>

Files:

- `Sources/ContainerBuild/Builder.swift`: model and encode named-stage
  metadata with all-stage precedence.
- `Sources/ContainerCommands/BuildCommand.swift`: parse, normalize, validate,
  and forward repeatable/comma-separated filters.
- `Tests/ContainerBuildTests/BuilderMetadataTests.swift`: metadata contract.
- `Tests/ContainerCommandsTests/BuildCommandTests.swift`: CLI contract.
- `Package.swift`: exact immutable Builder image pin.

Builder dependency:

- signed shim implementation:
  `af599a5c9cae51d7625da57d2220bd913f60d4a1`;
- merged shim commit:
  `f97cddf5b3aae2426a094613793c11c41b1d2e53`;
- tag: `current-30068004175-f97cddf5b3aa`;
- digest:
  `sha256:d993210e3960bce33a84e061d6cb96385b43277fe94a7492fd6c60b6317d2197`.

## Validation

```console
swift test
make check
make coverage
```

- Unit suite: 1,137 tests passed in the coverage run.
- Coverage: 38.77% lines, 40.48% functions, 40.59% regions.
- Swift formatting and Hawkeye license checks passed.
- PR signature checks and hosted build run `30068180079`: passed.
- The downstream strict fixture performed two Docker Compose V2 builds and
  two matching macOS source-runtime builds; both implementations changed the
  selected stage token on the second build.

## Compatibility and risk

- Existing callers of `--no-cache` are unchanged.
- Filters do not create stored daemon or image metadata.
- Invalid empty filters fail before Builder startup.
- No Containerization change is required.
