# feat(logs): add container logging policy model

## Template

This PR draft follows `.github/pull_request_template.md`.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [ ] Documentation update

## Motivation and Context

This is the first small runtime slice needed before `apple/container` can support Compose-style local logging policy. Docker Compose accepts service-level `logging.driver` and `logging.options`; `container-compose` can own Compose-specific validation and formatting, but the runtime needs a typed place to store per-container local log capture policy before later PRs can add disabled capture, retention fields, and writer rotation.

This PR intentionally adds only the data model and backward-compatible container configuration plumbing. It does not add CLI flags or change runtime write behavior.

Following JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), Docker driver aliases such as `json-file`, `local`, and `none` should be translated in `container-compose`; the Apple model should remain a typed local capture/retention primitive.

Related:

- Supports part of [apple/container#1752](https://github.com/apple/container/issues/1752).
- Builds alongside the log retrieval direction in [apple/container#1592](https://github.com/apple/container/pull/1592).
- Unblocks later local logging slices for disabled capture, local retention fields, and local rotation.

## What Changed

- Adds `ContainerLogConfiguration` to `ContainerResource`.
- Adds a local `Storage` enum with `.local` as the default capture backend.
- Adds optional local rotation policy fields:
  - `maxSizeInBytes`
  - `maxFileCount`
- Adds `ContainerConfiguration.logging`.
- Decodes missing `logging` values as `.default` so existing persisted container configurations remain readable.
- Adds focused configuration round-trip/default decoding tests.

## Non-Goals

- This does not add `container create/run --log-driver` or `--log-opt`.
- This does not implement disabled capture.
- This does not rotate files.
- This does not add remote logging drivers.
- This does not add Compose-specific policy, prefixes, colors, project labels, or service fan-out.

## Intended Review Delta

The code-bearing local integration commit for this slice is:

- `e41e630 feat(logs): add container logging policy model`

The handoff files are:

- `ISSUE-logs-local-policy-model.md`
- `PR-logs-local-policy-model.md`

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [ ] Added/updated docs

Local verification:

```bash
swift test --filter ContainerConfigurationLoggingTests
swift test --filter ContainerConfigurationTests
git diff --check
```

Expected focused coverage:

- Logging policy round-trips through `ContainerConfiguration`.
- Missing `logging` decodes as `.default` for backward compatibility.

## Compatibility Notes

Existing containers without a serialized `logging` key continue to decode with local log capture enabled. Later PRs should keep `.local` as the default runtime behavior so the existing `container logs` user experience is preserved unless a caller explicitly requests a different local policy.

## Remaining Risks

- The exact remote-driver story is intentionally unresolved. This model should remain local-policy oriented until maintainers decide whether `apple/container` should ever pass through remote Docker logging drivers.
- Later PRs must validate `maxSizeInBytes` and `maxFileCount` at caller boundaries before passing values into this model.
