# Pull Request

## Summary

- Preserve unsupported project network `driver`, `attachable`, `enable_ipv4`,
  `enable_ipv6`, and `ipam.options` markers across the compose-go to Swift
  handoff.
- Reject those semantics before runtime side effects while retaining mapped
  bridge/default behavior and IPv6 subnets.
- Document the remaining Apple runtime blocker.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Compose-go v2.12.1 exposes the current project network fields, and the approved
compose-go PR #870 confirms `IPAMConfig.Options` belongs in that typed model.
Docker Compose preserves all five fields in `config` and tracks
docker/compose#13785 for passing IPAM options through to Docker Engine network
creation. Apple network creation cannot currently represent each requested
semantic, so `container-compose` must reject the unsupported subset instead of
silently dropping it.

References:

- Docker Compose issue: <https://github.com/docker/compose/issues/13785>
- Approved compose-go model PR: <https://github.com/compose-spec/compose-go/pull/870>
- Compose network reference: <https://docs.docker.com/reference/compose-file/networks/>
- Compose network IPAM reference: <https://docs.docker.com/reference/compose-file/networks/#ipam>

## Commit Tracking

- Compose rejection code is the current `fix(networks): reject unsupported project network options` slice in `stephenlclarke/container-compose`.
- No Apple fork change is included in this slice. Mapping support needs future
  Apple-shaped network configuration primitives.

## Implementation Details

- `projectNetworkValues` separates mapped bridge/default and explicit-subnet
  behavior from custom driver, attachment, IP-family, and IPAM gaps.
- Go normalizer tests cover both mapped defaults and the complete unsupported
  field list alongside existing IPAM checks.
- Swift orchestration tests prove rejection happens before command or resource
  side effects.
- The Docker Compose parity fixture checks the same fields against Compose
  5.3.1 config output.
- `STATUS.md` names every current top-level network attribute and blocker.

## Docker Compose Compatibility Notes

Supported:

- Default bridge behavior, ordinary IPv4, and one explicitly mapped IPv6 subnet
  remain supported.
- Unsupported project network semantics are recognized and rejected before
  side effects instead of being silently ignored.

Remaining gap:

- Custom drivers, `attachable: true`, IPv4 disabling, automatic IPv6 allocation,
  and IPAM driver options remain blocked until Apple exposes matching network
  creation primitives.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter 'ComposeOrchestratorTests.upRejectsUnsupportedProjectNetworkOptionsBeforeSideEffects'
make docker-compose-network-ipam-options-parity
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
