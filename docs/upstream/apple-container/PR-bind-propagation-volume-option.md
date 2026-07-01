# Preserve bind propagation volume options

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Motivation and Context

Higher-level callers can represent bind propagation using the existing short `--volume` option list. `apple/container` already parses that option list generically, but this behavior was not pinned by a focused unit test. The test protects compatibility for callers that need `ro,rslave` style mount options without adding a Docker Compose-specific API to Apple/container.

## Commit Tracking

- Container code commit: `037f0431d1d2faa01ae45f42233e40066d54dfff` in `stephenlclarke/container` (`test(mounts): cover bind propagation volume option`).
- Compose mapping code is tracked separately in `docs/upstream/container-compose/PR-bind-propagation.md`.
- No apple/containerization commit is required because mount options already flow through `Mount.options` and OCI bind mount generation.

## Implementation Details

- Added parser coverage for a short bind volume with `ro,rslave`.
- Verified the parsed filesystem source, destination, and option list.
- Left `Parser.mount(type=bind,...)` unchanged; Compose renders the existing short `--volume` form for bind mounts.

## Testing

```bash
swift test --filter ParserTest/testVolumeBindPropagationOption
swift build --product container
git diff --check
```

## Compatibility Notes

- Existing short-volume behavior is unchanged.
- This test does not add or expose a new CLI flag.
- A future typed mount API could expose propagation structurally, but the current compatibility path remains the generic short volume option list.

## Remaining Risks

- The test verifies parser preservation, not Linux kernel propagation behavior inside a running VM.
