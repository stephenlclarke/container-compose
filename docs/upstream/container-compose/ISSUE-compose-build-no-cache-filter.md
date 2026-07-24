# Complete Compose named no-cache stage parity

## Problem

The normalizer omitted Compose `build.no_cache_filter`, so both normalized
`config` output and `build --print` lost the field. Live builds could only
forward the all-stage `build.no_cache` Boolean because the matched Container
runtime did not yet expose named stage filters.

Docker Compose V2 preserves this configuration:

```yaml
services:
  app:
    build:
      context: .
      no_cache_filter:
        - base
        - compile
```

and invalidates those stages on every build.

## Ownership

- compose-go parses and validates the Compose field.
- `container-compose` preserves the normalized value, renders Buildx bake
  JSON, and forwards repeated generic runtime options.
- Container carries the named stages over its existing Builder metadata.
- The Builder shim preserves the value for BuildKit.
- Containerization requires no change.

## Expected behavior

- Preserve `no_cache_filter` in normalized JSON.
- Render `no-cache-filter` as a Buildx bake array.
- Forward every stage as `container build --no-cache-filter STAGE`.
- Preserve existing all-stage `no_cache` behavior.
- Prove selected-stage rebuilding against Docker Compose V2 and the matching
  macOS source runtime.
- Keep Windows-only behavior out of scope.

## Acceptance criteria

- [x] Go normalizer coverage includes the field.
- [x] Swift model, live command, and bake tests include two stage names.
- [x] A real Compose YAML fixture performs two builds per implementation.
- [x] Docker Compose V2 5.3.1 model and live behavior pass.
- [x] Matching macOS source runtime behavior passes on this MBP.
- [x] Full Swift and Go coverage thresholds pass.
- [x] Exact upstream implementation commits and image digest are recorded.

## Implementation evidence

- Compose signed implementation:
  `cb66a818af15615acf44155b4aad95e06c6b4d9a`
  (`feat(build): add named no-cache stage filters`).
- Container signed commits:
  `acad796bcd9e5a6cd0fd5afe7395eb7192073bf4` and
  `03b34f3955166229c49dd45709c7291b84c9a8a8`.
- Builder-shim signed commit:
  `af599a5c9cae51d7625da57d2220bd913f60d4a1`.
- Builder image digest:
  `sha256:d993210e3960bce33a84e061d6cb96385b43277fe94a7492fd6c60b6317d2197`.
