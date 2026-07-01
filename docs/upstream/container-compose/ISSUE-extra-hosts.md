# Compose compatibility gap: service extra_hosts static host entries

## Compose Surface

Compose service `extra_hosts` adds host-to-IP mappings to a service container's network configuration, typically `/etc/hosts` on Linux:

```yaml
services:
  api:
    image: alpine
    extra_hosts:
      - "db=10.0.0.5"
      - "myhostv6=[::1]"
```

Compose supports short syntax with `HOST=IP` or `HOST:IP`, bracketed IPv6 values, and long mapping syntax. The compose-go normalizer canonicalizes these forms into static host entries that this plugin can pass to the runtime.

## Docker Compose v2 Behavior

Docker Compose writes each static host-to-IP mapping into the created container's host resolution configuration before the workload starts.

Reference surfaces:

- Compose service `extra_hosts`: [extra_hosts](https://docs.docker.com/reference/compose-file/services/#extra_hosts)
- Docker `container run --add-host`: [--add-host](https://docs.docker.com/reference/cli/docker/container/run/#add-host)

## Current container-compose Behavior

Before this change, any non-empty service `extra_hosts` list was rejected as an `apple/container` runtime gap.

With this change, `container-compose` accepts static IP-literal `extra_hosts`, validates them before creating resources, and maps them to the plugin-owned host-entry projection. The current live execution path still renders `container run/create --add-host` through the command-vector bridge while typed service creation is being wired.

## Remaining Gaps

- Docker's `host-gateway` magic value is handled by the separate `docs/upstream/apple-container/ISSUE-host-gateway.md` / `docs/upstream/apple-container/PR-host-gateway.md` slice on the fork-backed branch.
- `domainname` still needs runtime host identity controls.
- `hostname` is handled by the separate `docs/upstream/container-compose/ISSUE-service-hostname.md` / `docs/upstream/container-compose/PR-service-hostname.md` slice on the fork-backed branch.
- `links` and `external_links` still need legacy link/alias semantics, or an explicit decision to keep them unsupported.
- Released upstream support remains blocked until `apple/container` accepts an explicit host-entry API such as [apple/container#1340](https://github.com/apple/container/pull/1340), [apple/container#1563](https://github.com/apple/container/pull/1563), or an equivalent shape.

## Likely Owner

`apple/container` owns creation-time `/etc/hosts` generation. `container-compose` owns translating Compose `extra_hosts` syntax into typed runtime host-entry projections and keeping Compose-specific validation outside the runtime.

## Minimal Example

```yaml
name: extra-hosts-demo

services:
  api:
    image: alpine
    command: ["cat", "/etc/hosts"]
    extra_hosts:
      - "db=10.0.0.5"
      - "myhostv6=[::1]"
```

Expected runtime behavior on the fork-backed integration branch:

- `container-compose` currently emits `--add-host db:10.0.0.5` through the command-vector bridge.
- `container-compose` currently emits `--add-host myhostv6:::1` through the command-vector bridge.
- The runtime appends the two entries to `/etc/hosts` before the container workload starts.

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `STATUS.md` and relevant upstream docs.
