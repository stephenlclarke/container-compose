# Feature request: explicit container hostname configuration

## Feature or enhancement request details

Docker exposes a creation-time hostname option for the container UTS namespace:

```sh
docker container run --hostname api-01 alpine hostname
```

Docker Compose exposes the same runtime identity through the service `hostname` key:

```yaml
services:
  api:
    image: alpine
    hostname: api-01
```

`apple/container` already chooses a default hostname from the first network attachment hostname, or from the container ID when no network hostname is present. It does not currently expose a persisted, caller-controlled hostname on the typed container configuration path.

This gap blocks Compose `hostname` support in `container-compose` even though the lower `containerization` runtime already has `LinuxContainer.Configuration.hostname`, and the OCI spec model includes `hostname`.

Per JLogan's guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), the useful Apple-facing slice is the typed runtime configuration primitive. Docker/Compose field parsing and any Docker-shaped `--hostname` bridge should stay in `container-compose` or be treated as local validation plumbing, not as the required upstream API shape.

Relevant references:

- Docker CLI `container run --hostname`: <https://docs.docker.com/reference/cli/docker/container/run/>
- Compose service `hostname`: <https://docs.docker.com/reference/compose-file/services/#hostname>
- Related networking and identity discussions: [apple/container#1563](https://github.com/apple/container/pull/1563), [apple/container#1340](https://github.com/apple/container/pull/1340), [apple/container#673](https://github.com/apple/container/issues/673), [apple/container#282](https://github.com/apple/container/issues/282)

## Proposed behavior

- Add a `hostname` field to `ContainerConfiguration`.
- Validate the supplied hostname with RFC1123 label rules before creating any container resources when Apple accepts direct user input for this field.
- Preserve current default behavior when no explicit hostname is provided.
- Keep `domainname` out of this change because the current lower runtime configuration exposes `hostname` but not a domain-name field.

## Minimal example

Expected behavior:

- The created Linux container receives `api-01` as its runtime hostname.
- Existing callers that omit an explicit hostname keep the current default network-derived or container-ID-derived hostname.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
