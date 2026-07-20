# Pull Request

## Summary

- Preserve project network `ipam.options` through the compose-go to Swift
  handoff and config/convert output.
- Keep it inspection-only on the local vmnet path, matching Docker Compose
  local-mode behavior instead of forwarding a fabricated runtime option.
- Retain early rejection for custom drivers and disabled IP families.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Compose-go v2.12.1 exposes the current project network fields, and the approved
compose-go PR #870 confirms `IPAMConfig.Options` belongs in that typed model.
Docker Compose preserves the options in `config` and tracks docker/compose#13785
for passing them through to Docker Engine network creation. The generic vmnet
path automatically allocates IPv6, so Compose accepts `enable_ipv6: true` with
or without an explicit subnet. It cannot disable that allocation, so
`container-compose` continues to reject `enable_ipv6: false` and the other
runtime-backed unsupported subset instead of silently dropping them.

References:

- Docker Compose issue: <https://github.com/docker/compose/issues/13785>
- Approved compose-go model PR: <https://github.com/compose-spec/compose-go/pull/870>
- Compose network reference: <https://docs.docker.com/reference/compose-file/networks/>
- Compose network IPAM reference: <https://docs.docker.com/reference/compose-file/networks/#ipam>

## Commit Tracking

- Compose implementation is the signed `fix(network): retain local IPAM options` slice in `stephenlclarke/container-compose`, covering `Tools/compose-normalizer/main.go`, `Sources/ComposeCore/NormalizedProject.swift`, and `Tools/parity/check-compose-network-ipam-options.sh`.
- Automatic IPv6 enablement is superseded by [`55d00074864d21c70c9b03995886fbc9cf9e57de`](https://github.com/stephenlclarke/container-compose/commit/55d00074864d21c70c9b03995886fbc9cf9e57de) and [the dedicated handoff](PR-network-ipv6-auto.md).
- No Apple fork change is included in this slice. The remaining driver and
  IP-family controls need future Apple-shaped network configuration primitives.

## Implementation Details

- `normalizedNetwork.IPAMOptions` and `ComposeNetwork.ipamOptions` retain the
  typed Compose metadata without creating a vmnet-specific abstraction.
- `networkIPAMValues` no longer classifies an IPAM option as an unsupported
  runtime primitive; the existing custom-driver and IP-family diagnostics stay
  unchanged.
- Go and Swift normalizer tests cover retention, and the Docker Compose parity
  fixture verifies config preservation, successful dry-run orchestration, and
  absence of a fabricated vmnet option.
- `STATUS.md` names every current top-level network attribute and blocker.

## Docker Compose Compatibility Notes

Supported:

- Default bridge behavior, ordinary IPv4, one explicitly mapped IPv6 subnet,
  `enable_ipv6: true` with automatic vmnet allocation, and inspection-only
  `ipam.options` remain supported.
- Custom drivers and IP-family-disable semantics remain recognized and rejected
  before side effects instead of being silently ignored.

Remaining gap:

- Custom drivers and IPv4 or IPv6 disabling remain blocked until Apple exposes
  matching network creation primitives. `attachable: true` is already accepted
  by the macOS local vmnet path; IPAM options are retained but intentionally
  ignored, matching Docker Compose local mode.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter 'ComposeNormalizerTests.normalizerPreservesInspectionOnlyIPAMOptions'
make docker-compose-network-ipam-options-parity
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
