<!-- markdownlint-disable MD013 -->

# feat(logs): support disabled local log capture

## Template

This PR draft follows `.github/pull_request_template.md`.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [ ] Documentation update

## Motivation and Context

This is the next small runtime slice after the typed local logging policy model. Docker supports disabling persisted container logs with `--log-driver none`, and Docker Compose can express the same intent with service-level `logging.driver: none`. `container-compose` can own Compose-specific validation and mapping, but `apple/container` needs the typed runtime primitive that actually suppresses persisted local stdout/stderr capture.

The change keeps the default behavior unchanged. Containers continue using local persisted capture unless the caller explicitly configures disabled storage. Attached stdio remains independent from persisted log capture, so interactive or attached clients can still receive process output while the runtime avoids writing `stdio.log` / `stdio.jsonl` entries for that container.

Related:

- Supports part of [apple/container#1752](https://github.com/apple/container/issues/1752).
- Builds on the typed local logging policy model described in `docs/upstream/apple-container/ISSUE-logs-local-policy-model.md` / `docs/upstream/apple-container/PR-logs-local-policy-model.md`.
- Complements the log retrieval direction in [apple/container#1592](https://github.com/apple/container/pull/1592).
- Unblocks `container-compose` mapping of Compose `logging.driver: none` to the runtime policy.
- Follows JLogan's guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328) by leaving Docker-shaped parser compatibility in `container-compose`.

## What Changed

- Adds `ContainerLogConfiguration.Storage.none`.
- Keeps `.local` as the default `ContainerLogConfiguration` storage backend.
- Routes runtime log-writer creation through a small policy helper.
- Returns no persisted log writer when storage is `.none`.
- Separates attached stdio fan-out from persisted log capture so callers can still receive output when capture is disabled.
- Adds focused tests for configuration round-trip, disabled writer creation, empty writer fan-out, and attached-stdio preservation.

## Non-Goals

- This does not add `container create/run --log-driver`.
- This does not add Compose-specific mapping or validation.
- This does not add remote logging drivers.
- This does not add writer-level rotation.
- This does not change `container logs` behavior for containers using the default `.local` policy.

## Intended Review Delta

The code-bearing local integration commit for this slice is:

- `6cbf778 feat(logs): support disabled log storage`

The handoff files are:

- `ISSUE-logs-disabled-local-capture.md`
- `PR-logs-disabled-local-capture.md`

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [ ] Added/updated docs

Local verification:

```bash
swift test --filter ContainerConfigurationLoggingTests
swift test --filter ContainerLogFileWriterTests
git diff --check
```

Expected focused coverage:

- `ContainerConfiguration.logging.storage == .none` round-trips through persisted configuration.
- Runtime log-writer creation returns `nil` for disabled capture.
- Runtime output fan-out returns `nil` when neither attached stdio nor persisted capture is present.
- Attached stdout/stderr handles still receive bytes when persisted capture is disabled.

## Compatibility Notes

Existing containers and callers keep the default `.local` persisted capture behavior. `container-compose` can map Docker-compatible `none` logging policy into this runtime option while keeping service prefixes, colors, replica fan-out, and Compose validation outside `apple/container`.

## Remaining Risks

- A Docker-shaped CLI mapping for `--log-driver none` is no longer a plugin dependency; add one only if Apple maintainers want that native command convenience.
- Remote logging drivers remain intentionally out of scope until maintainers decide whether `apple/container` should expose them.
- The exact accepted type names may shift if the typed local logging policy model changes during upstream review.
