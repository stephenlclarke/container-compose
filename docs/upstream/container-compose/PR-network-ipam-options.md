# Pull Request

## Summary

- Treat Compose `networks.<name>.ipam.options` as an explicit unsupported network field.
- Add Go and Swift normalizer regression coverage so the unsupported marker survives the compose-go to Swift handoff.
- Document the remaining Apple runtime blocker.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Compose-go v2.12.1 exposes `IPAMConfig.Options`, and the approved upstream compose-go PR #870 confirms this field belongs in the typed model. Docker Compose also tracks docker/compose#13785 for passing those options through to Docker Engine network creation. `container-compose` cannot map the field yet because Apple network creation does not expose a Docker-compatible IPAM option surface, but silently dropping it is worse than rejecting it.

References:

- Docker Compose issue: <https://github.com/docker/compose/issues/13785>
- Compose-go approved model fix: <https://github.com/compose-spec/compose-go/pull/870>
- Compose network IPAM reference: <https://docs.docker.com/reference/compose-file/networks/#ipam>

## Commit Tracking

- Compose rejection code is the current `fix(normalizer): reject unsupported ipam options` slice in `stephenlclarke/container-compose`.
- No Apple fork change is included in this slice. Mapping support needs a future Apple-shaped network IPAM option primitive.

## Implementation Details

- `networkIPAMValues` now appends `ipam.options` to the unsupported network field list when compose-go reports any IPAM option values.
- Go normalizer tests cover the unsupported marker alongside the existing IPAM driver, gateway, range, aux-address, and duplicate-subnet checks.
- Swift normalizer tests cover decoding the unsupported marker from a real Compose file.
- `STATUS.md` and `README.md` now call out the runtime blocker explicitly.

## Docker Compose Compatibility Notes

Supported:

- The field is recognized and rejected before side effects instead of being silently ignored.

Remaining gap:

- Docker-compatible execution of IPAM driver options remains blocked until Apple exposes a matching network creation primitive.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter 'ComposeNormalizerTests/normalizerMarksIPAMOptionsUnsupported'
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
