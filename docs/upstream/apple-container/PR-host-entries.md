<!-- markdownlint-disable MD013 -->

# feat(api): add explicit host entries

## Template

This PR draft follows `.github/pull_request_template.md`.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This is a small host-entry slice needed by higher-level callers and Compose-style orchestrators. `apple/container` already owns generation of the Linux container `/etc/hosts` file, so callers need a first-class typed runtime option instead of patching the file after the container starts.

The design deliberately references and narrows existing upstream work:

- [apple/container#1340](https://github.com/apple/container/pull/1340) adds the resource-level host-entry concept.
- [apple/container#1563](https://github.com/apple/container/pull/1563) adds a Docker-compatible `--add-host` flag.

This fork slice combines those two directions so `container-compose` can map Compose `extra_hosts` without adding Compose-specific policy to the runtime. If upstream accepts one of those PRs first, this change should be reshaped to the accepted API rather than submitted as a duplicate.

Following JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), the durable upstream ask is the `ContainerConfiguration` model and runtime `/etc/hosts` behavior. The local `--add-host` parser bridge exists only because the current plugin create path still uses command vectors.

## What Changed

- Adds `ContainerConfiguration.HostEntry`.
- Adds defaulted `ContainerConfiguration.hosts`.
- Decodes missing `hosts` from older configuration JSON as `[]`.
- Validates static IPv4, IPv6, and bracketed IPv6 host entries before runtime configuration.
- Appends configured host entries while building the runtime `/etc/hosts` file.
- Adds focused tests for configuration round-trip/backward compatibility and runtime host-entry ordering.
- The local fork also carried repeatable `container run/create --add-host` parsing so the existing command-vector create path could validate this primitive; an upstream PR should drop or soften that bridge if maintainers prefer typed-only configuration.

## Commit Tracking

- Container code commit: `bf1d6b4` in `stephenlclarke/container` (`feat(api): add explicit host entries`).
- Lower runtime code commit: not required.
- Compose mapping code commit: `7855a19` in `stephenlclarke/container-compose` (`feat(network): map compose extra hosts`), not part of this Apple PR.

## Non-Goals

- This does not add Compose-specific service aliasing to `apple/container`.
- This does not implement legacy Compose `links` or `external_links`.
- This does not implement Docker's `host-gateway` magic value. That should be a separate runtime follow-up because it needs gateway resolution at container creation time.
- This does not add multi-network alias or DNSRR behavior.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Local verification:

```bash
swift test --filter 'ParserTest/testHostEntriesParserAcceptsIPv4WithColonSeparator|ParserTest/testHostEntriesParserAcceptsIPv6WithEqualsSeparator|ParserTest/testHostEntriesParserAcceptsBracketedIPv6|ParserTest/testHostEntriesParserAcceptsMultipleEntries|ParserTest/testHostEntriesParserRejectsMissingSeparator|ParserTest/testHostEntriesParserRejectsEmptyHostname|ParserTest/testHostEntriesParserRejectsEmptyAddress|ParserTest/testHostEntriesParserRejectsInvalidAddress|ParserTest/testManagementFlagsAcceptsAddHost|ContainerConfigurationHostEntryTests|RuntimeServiceHostsTests'
```

Result: 13 selected tests passed.

Additional local checks:

```bash
make check
make test
```

Result: `make check` passed; `make test` passed with 708 tests.

## Compatibility Notes

The `hosts` field is additive and defaults to an empty list when missing, so existing stored container configurations continue to decode.

Runtime behavior remains generic: the new entries are appended to `/etc/hosts` after the default localhost and primary container hostname entries. Higher-level tools such as `container-compose` remain responsible for translating their own config syntax into typed host entries.

## Docker And Compose Parity Notes

Docker Compose documents `extra_hosts` short syntax with `HOSTNAME=IP`, also allowing `HOSTNAME:IP`, plus bracketed IPv6 values. This parser accepts those concrete host-to-IP forms and rejects invalid addresses before container creation.

Docker's special `host-gateway` value remains a follow-up so the first host-entry PR can stay focused on static entries and existing upstream PR direction.

## Remaining Risks

- Maintainers may prefer the exact public property name from [apple/container#1340](https://github.com/apple/container/pull/1340) or [apple/container#1563](https://github.com/apple/container/pull/1563). The fork should rebase to whichever API shape is accepted upstream.
- The Compose plugin will need to keep `host-gateway`, `links`, `external_links`, and custom hostname/domain behavior as separate runtime-gap checks until those primitives exist.
