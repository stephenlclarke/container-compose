<!-- markdownlint-disable MD013 -->

# [Request]: Add explicit host entries to container configuration

## Template

This issue draft follows `.github/ISSUE_TEMPLATE/02-feature.yml`.

## Feature or enhancement request details

`apple/container` currently generates a minimal `/etc/hosts` file for each Linux container: localhost plus the container's primary interface hostname. Callers cannot provide additional host-to-IP mappings before the workload starts.

That blocks higher-level callers such as `container-compose` from representing Compose service `extra_hosts`. A Compose plugin can parse and normalize those fields, but it cannot safely patch `/etc/hosts` after startup because application processes may resolve names before the patch happens, and distroless images may not have shell tools for post-start mutation.

Per JLogan's guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), this Apple-facing slice should stay focused on the typed host-entry model and pre-start `/etc/hosts` generation. Docker/Compose `--add-host` syntax, `extra_hosts` normalization, and error wording belong in `container-compose`.

Requested behavior:

- Add a typed, persisted host-entry model to `ContainerConfiguration`.
- Decode older container configurations without host entries as an empty list.
- Accept IPv4, IPv6, and bracketed IPv6 addresses.
- Append caller-provided entries after the default localhost and primary-container entries while generating `/etc/hosts`.

Related upstream work:

- [apple/container#1340](https://github.com/apple/container/pull/1340): adds explicit host entries to `ContainerConfiguration`.
- [apple/container#1563](https://github.com/apple/container/pull/1563): adds a Docker-compatible `--add-host` CLI surface.

This local slice combines those directions in the fork so `container-compose` can prove Compose `extra_hosts` against the same runtime boundary. If either upstream PR lands first, this work should be rebased to match the accepted API shape instead of submitted as a competing duplicate. The local parser bridge should not be treated as required upstream shape.

References:

- [Docker Compose service `extra_hosts`](https://docs.docker.com/reference/compose-file/services/#extra_hosts)
- [Docker `container run --add-host`](https://docs.docker.com/reference/cli/docker/container/run/#add-host)

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
