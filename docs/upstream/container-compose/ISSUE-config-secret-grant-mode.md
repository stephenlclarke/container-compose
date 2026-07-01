# Compose compatibility gap: generated config and secret grant modes

## Compose Surface

Service-level `configs` and `secrets` long syntax can include a `mode` field that controls the file permissions visible in the container:

```yaml
services:
  api:
    image: example/api
    configs:
      - source: inline_config
        target: /etc/app.conf
        mode: 0555
    secrets:
      - source: runtime_token
        target: api-token
        mode: 0440

configs:
  inline_config:
    content: |
      enabled=true

secrets:
  runtime_token:
    environment: API_TOKEN
```

## Docker Compose v2 Behavior

Docker Compose documents service grant `mode` as an octal file permission. The default is `0444`, writable bits are ignored, and executable bits may be set. Docker Compose only honors `uid`, `gid`, and `mode` for secrets when the source is `environment`; file-backed secrets are bind-mounted and their long-syntax metadata is silently ignored.

Reference surfaces:

- Compose service `configs`: [configs](https://docs.docker.com/reference/compose-file/services/#configs)
- Compose service `secrets`: [secrets](https://docs.docker.com/reference/compose-file/services/#secrets)

## Current container-compose Behavior

Before this change, generated runtime config/secret files used fixed permissions chosen by `container-compose`. A service grant mode did not affect generated file permissions and did not affect the service config hash, so a mode-only change could fail to trigger recreation.

With this change, generated config and secret grants apply service-level `mode`, remove writable bits, preserve executable bits, and include the effective mode in the materialized file name. File-backed grants continue to use Docker Compose's bind-mount behavior and do not mutate source file metadata.

## Likely Owner

`container-compose` owns generated-file mode behavior because it owns the local materialized file before passing it to `apple/container` as a read-only bind mount.

`apple/container` should own future ownership-remapping primitives. Requests for `uid` or `gid` on generated grants still need a runtime capability because a local bind mount cannot reliably project arbitrary in-container ownership.

## Minimal Example

```yaml
name: materialized-grant-mode-demo

services:
  api:
    image: alpine
    configs:
      - source: inline_config
        target: /etc/executable.conf
        mode: 0755
    secrets:
      - source: env_secret
        target: api-token
        mode: 0660

configs:
  inline_config:
    content: |
      executable=true

secrets:
  env_secret:
    environment: API_TOKEN
```

Expected runtime behavior:

- The generated config file is chmodded to `0555` because writable bits from `0755` are ignored.
- The generated secret file is chmodded to `0440` because writable bits from `0660` are ignored.
- Changing only either service grant mode changes the materialized source path and therefore the service config hash.

## References

- Docker Compose service configs: [services.configs](https://docs.docker.com/reference/compose-file/services/#configs)
- Docker Compose service secrets: [services.secrets](https://docs.docker.com/reference/compose-file/services/#secrets)
- Related materialization issue: `ISSUE-config-secret-materialization.md`
- Related compatibility docs: `STATUS.md`
- Related planning docs: `STATUS.md` and relevant upstream docs

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `STATUS.md` and relevant upstream docs.
