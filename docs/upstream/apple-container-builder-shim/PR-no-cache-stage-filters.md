# Pull request: preserve named no-cache stage filters

## Summary

- Preserve the value of the existing Builder `no-cache` metadata key.
- Continue using an empty value for all-stage cache invalidation.
- Forward a non-empty comma-separated stage list to BuildKit unchanged.
- Add table-driven coverage for the complete absent/empty/named/repeated
  value boundary.

Closes
[`ISSUE-no-cache-stage-filters.md`](ISSUE-no-cache-stage-filters.md).

## Type of change

- [x] Generic Builder metadata correctness
- [x] Unit tests
- [ ] Compose-specific behavior
- [ ] Windows behavior

## Apple-shaped boundary

The patch changes only the existing metadata-to-Dockerfile-frontend adapter.
It adds no Compose schema, daemon state, or new RPC. `BOpts.NoCache` becomes an
optional string so the shim can distinguish absent metadata from a present
empty value while retaining named-stage content.

## Commit and code map

Signed implementation:

- `af599a5c9cae51d7625da57d2220bd913f60d4a1`
  `feat(build): preserve no-cache stage filters`

Merged fork commit:

- `f97cddf5b3aae2426a094613793c11c41b1d2e53`
- Fork PR: <https://github.com/stephenlclarke/container-builder-shim/pull/5>

Files:

- `pkg/build/buildopts.go`: retain optional metadata content and emit it as a
  Dockerfile frontend attribute.
- `pkg/build/build.go`: use the shared frontend-attribute projection rather
  than overwriting the value with an empty string.
- `pkg/build/buildopts_test.go`: prove absent, all-stage, named-stage, and
  last-value behavior.

## Validation

```console
go test ./...
make lint
make build
make coverage
make check-licenses
```

- All commands passed.
- Repository statement coverage: 44.5%.
- Fork validation workflow `30067889915`: passed.
- Current image workflow `30068004175`: passed.
- Published image digest:
  `sha256:d993210e3960bce33a84e061d6cb96385b43277fe94a7492fd6c60b6317d2197`.
- The downstream two-build Docker Compose V2 5.3.1 and matching macOS runtime
  fixture passed.

## Compatibility and risk

- Empty `no-cache` metadata remains the all-stage form.
- Omitted metadata remains omitted.
- The last repeated metadata value still wins.
- The implementation is backward-compatible with Boolean callers that send
  only an empty value.
