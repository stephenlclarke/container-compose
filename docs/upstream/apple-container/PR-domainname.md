# Pull request: add explicit container domain-name configuration

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker exposes `docker container run --domainname` for setting the NIS domain name visible inside the container UTS namespace, and Docker Compose exposes the same concept with the service `domainname` key. `apple/container` already isolates UTS namespaces and has a fork-backed explicit hostname path, but it does not expose the matching typed domain-name primitive.

This change adds that missing runtime primitive without adding Compose-specific behavior to `apple/container`. `containerization` already carries OCI `domainname` in its spec model, but the checked-in `vminitd` path currently applies only `sethostname` directly. To keep this change small and local to `apple/container`, the runtime bridge maps `ContainerConfiguration.domainname` to the existing OCI sysctl path as `kernel.domainname`, which Linux exposes as the NIS domain name for the current UTS namespace. Following JLogan's guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), the durable upstream ask is the typed configuration field and runtime behavior; Docker-shaped CLI parsing stays in `container-compose` unless maintainers explicitly want an Apple-native command convenience.

References:

- Docker CLI `container run --domainname`: <https://docs.docker.com/reference/cli/docker/container/run/>
- Compose service `domainname`: <https://docs.docker.com/reference/compose-file/services/#domainname>
- OCI runtime config `domainname`: <https://specs.opencontainers.org/runtime-spec/config/>
- Linux UTS namespace behavior: <https://man7.org/linux/man-pages/man7/uts_namespaces.7.html>
- Existing hostname/FQDN discussion: [apple/container#1011](https://github.com/apple/container/issues/1011)
- Related DNS configuration work: [apple/container#817](https://github.com/apple/container/issues/817), [apple/container#1614](https://github.com/apple/container/pull/1614)

## Commit Tracking

- Container code commit: `183ac5b` in `stephenlclarke/container` (`feat(runtime): add container domain names`).
- Lower runtime code commit: not required.
- Compose mapping code commit: `bcbfb3f` in `stephenlclarke/container-compose` (`feat(runtime): map compose domain names`), not part of this Apple PR.

## Implementation Details

- Added `ContainerConfiguration.domainname`.
- Reused hostname-style RFC1123 validation for direct caller input.
- Set `ContainerConfiguration.domainname` during client-side configuration assembly.
- Added `RuntimeService.resolvedSysctls(config:)` so the runtime can merge user sysctls with the domain-name sysctl in one tested boundary.
- Mapped `domainname` to `kernel.domainname` before handing the configuration to `containerization`.
- Rejected conflicting direct API input when `domainname` and `sysctls["kernel.domainname"]` differ.
- The local fork also carried `--domainname <domainname>` parser and command-reference changes so the existing create path could validate the primitive; an upstream PR should drop or soften that bridge if maintainers prefer typed-only configuration.

## Compatibility Notes

- This preserves existing behavior when no domain name is supplied.
- The `domainname` setting is a generic container runtime primitive; Compose translation remains in `container-compose`.
- The sysctl bridge can be replaced later by direct `containerization` support for OCI `domainname` without changing the public `ContainerConfiguration.domainname`.
- This does not add Compose `domainname` parsing to `apple/container`, and it does not change DNS search-domain behavior.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused tests:

```sh
swift test --filter 'ParserTest/testDomainnameParserAcceptsRFC1123Name|ParserTest/testDomainnameParserRejectsInvalidLabel|ParserTest/testManagementFlagsAcceptsDomainname|ContainerConfigurationDomainnameTests|RuntimeServiceHostsTests/resolvedSysctlsMapsDomainname|RuntimeServiceHostsTests/resolvedSysctlsPreservesMatchingDomainnameSysctl|RuntimeServiceHostsTests/resolvedSysctlsRejectsConflictingDomainnameSysctl'
```

Additional checks:

```sh
make check
git diff --check
```
