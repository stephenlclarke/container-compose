# Add named build no-cache filters

## Problem

`container build --no-cache` invalidates every Dockerfile stage, but Container
did not expose the named-stage form used by BuildKit and Docker Compose:

```console
container build --no-cache-filter base --no-cache-filter compile .
```

The existing Builder metadata channel can carry the comma-separated stage
list, so this gap does not require a new runtime service or Containerization
API.

## Expected behavior

- Accept repeatable `--no-cache-filter STAGE` options.
- Accept comma-separated stages for Docker-compatible CLI composition.
- Trim surrounding whitespace and reject empty stage entries.
- Preserve the existing all-stage `--no-cache` behavior.
- When both forms are present, all-stage `--no-cache` wins.
- Omit the metadata key when neither form is present.
- Pin a Builder shim that preserves non-empty metadata values.

## Proposed implementation

Add `[String]` stage filters to the generic `Builder.BuildConfig`, normalize
the CLI values, and encode them as the value of the existing `no-cache`
metadata key. Keep Boolean all-stage behavior as the higher-precedence empty
value.

Signed commits:

- `acad796bcd9e5a6cd0fd5afe7395eb7192073bf4`
  `feat(build): add named no-cache filters`
- `03b34f3955166229c49dd45709c7291b84c9a8a8`
  `chore(build): pin no-cache filter builder shim`

## Acceptance criteria

- [x] Builder metadata tests cover omission, named stages, trimming, and
  all-stage precedence.
- [x] CLI tests cover repeated/comma-separated values and empty-stage errors.
- [x] The complete unit and coverage suites pass.
- [x] Strict formatting and license checks pass.
- [x] The pinned immutable Builder image reports the expected digest.
- [x] Docker Compose V2 and matching macOS runtime two-build parity pass.

## Validation evidence

- Full unit suite before the dependency pin: 1,136 tests passed.
- Pinned focused configuration suite: 28 tests passed.
- Coverage suite: 1,137 tests passed.
- Coverage: 38.77% lines, 40.48% functions, 40.59% regions.
- Matching runtime commit before merge:
  `03b34f3955166229c49dd45709c7291b84c9a8a8`.
- Matching Builder digest:
  `sha256:d993210e3960bce33a84e061d6cb96385b43277fe94a7492fd6c60b6317d2197`.
