# feat(api): add restart policy create options

## Fork Branch And Commit

- Fork branch: `stephenlclarke/container` `restart-policy-create-options`
- Commit: `c5668c19d139b1aeb7e2529cb1dedd01fb4532c1`

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This is the first small restart-policy slice for [apple/container#286](https://github.com/apple/container/issues/286). It also uses [apple/container#1258](https://github.com/apple/container/pull/1258) as design input, but narrows the diff to the create-time API surface so the public contract can be reviewed before restart scheduling is added.

Docker-compatible Compose support needs a runtime-owned policy shape for service `restart` values. Keeping this model in `ContainerCreateOptions` lets generic API callers and `container-compose` normalize to the same runtime option without adding Compose-specific code to `apple/container`. Following JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), Compose owns Docker/Compose restart value parsing and precedence; the Apple-facing ask is the typed policy plus runtime scheduler.

## Implementation Details

- Adds `ContainerRestartPolicy` with Docker-compatible modes:
  - `no`
  - `on-failure`
  - `always`
  - `unless-stopped`
- Adds optional `maximumRetryCount` for `on-failure:<max-retries>`.
- Adds `restartPolicy` to `ContainerCreateOptions`.
- Keeps persisted options backward compatible by decoding missing `restartPolicy` as `.no`.
- Normalizes direct API and decoded JSON policy shapes so retry counts only apply to `on-failure`; `on-failure:0` is stored as no retry cap, matching Docker/Moby semantics and Colima's Docker-runtime behavior.
- Rejects retry counts on non-`on-failure` policies.
- Rejects auto-remove with a non-default restart policy, matching Docker's `AutoRemove` / `RestartPolicy` mutual exclusion.
- The local fork also carried a `--restart` management flag and `Parser.restartPolicy` so the existing command-vector create path could validate the primitive; an upstream PR should drop or soften that bridge if maintainers prefer typed-only configuration.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Local validation:

```sh
/usr/bin/swift test --filter 'ParserTest|ContainerCreateOptionsTests'
```

Focused test evidence:

- `ContainerCreateOptionsTests` verifies restart-policy round trip, backward-compatible decode of missing policy, direct initializer normalization, and decoded JSON normalization.
- `ParserTest` in the local fork verifies the temporary command-vector bridge: default policy parsing, Docker-compatible values including `on-failure:0`, invalid values, retry-count scoping, and `--rm` conflict validation.

## Compatibility Notes

This change is additive for API clients. Existing callers that construct `ContainerCreateOptions(autoRemove:rootFsOverride:)` continue to compile because `restartPolicy` has a default value. Existing persisted options without a `restartPolicy` field decode as `.no`.

This PR does not restart containers yet. Follow-up slices should add the runtime scheduler/backoff behavior, restart-count inspection, and any update-time restart-policy changes.

## Compose Compatibility Notes

The typed modes intentionally cover Docker's documented `docker run --restart` values, including `on-failure:<max-retries>` and `unless-stopped`, because those are the modes Compose files commonly rely on. `on-failure:0` follows Docker/Moby semantics: zero means no retry cap, not zero retries. Compose value parsing and deploy-policy precedence remain in `container-compose`.

## Remaining Risks

- Runtime behavior still needs a follow-up PR before non-default policies have an effect.
- `unless-stopped` needs careful treatment when automatic restart on service startup is later designed, because Docker distinguishes it from `always` across daemon restarts.
- `ContainerSnapshot` and inspect/list output do not yet expose restart count or active restart state.
