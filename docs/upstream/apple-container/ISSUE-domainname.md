# Feature request: explicit container domainname configuration

## Feature or enhancement request details

Docker exposes a creation-time NIS domain name option for the container UTS namespace:

```sh
docker container run --domainname example.test alpine domainname
```

Docker Compose exposes the same runtime identity through the service `domainname` key:

```yaml
services:
  api:
    image: alpine
    domainname: example.test
```

`apple/container` already has an explicit hostname path on this fork, but it does not currently expose a matching typed domain-name configuration field. This gap blocks Compose `domainname` support in `container-compose` even though the OCI runtime spec includes `domainname`, Linux UTS namespaces isolate both hostname and NIS domain name, and `vminitd` already applies OCI sysctls before starting the workload.

Per JLogan's guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), the Apple-facing request should be the typed domain-name primitive and runtime application path. Docker/Compose `domainname` parsing belongs in `container-compose`; any local `--domainname` bridge is only temporary validation plumbing.

Relevant references:

- Docker CLI `container run --domainname`: <https://docs.docker.com/reference/cli/docker/container/run/>
- Compose service `domainname`: <https://docs.docker.com/reference/compose-file/services/#domainname>
- OCI runtime config `domainname`: <https://specs.opencontainers.org/runtime-spec/config/>
- Linux UTS namespace behavior: <https://man7.org/linux/man-pages/man7/uts_namespaces.7.html>
- Existing hostname/FQDN discussion: [apple/container#1011](https://github.com/apple/container/issues/1011)
- Related DNS configuration work: [apple/container#817](https://github.com/apple/container/issues/817), [apple/container#1614](https://github.com/apple/container/pull/1614)

## Proposed behavior

- Add a `domainname` field to `ContainerConfiguration`.
- Validate the supplied value with the same RFC1123 hostname-label rules used for explicit hostnames when Apple accepts direct user input for this field.
- Apply the value inside the container UTS namespace by setting `kernel.domainname` through the existing runtime sysctl path before the workload starts.
- Reject conflicting direct API input when `ContainerConfiguration.domainname` and `ContainerConfiguration.sysctls["kernel.domainname"]` specify different values.
- Preserve current behavior when no explicit domain name is provided.

## Minimal example

Expected behavior:

- The created Linux container receives `example.test` as its NIS domain name.
- Existing callers that omit an explicit domain name keep the current inherited/default UTS domain behavior.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
