# Pull request: wire block IO runtime settings

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This integration change brings the typed runtime-data portion of Chris George's [apple/container#1595](https://github.com/apple/container/pull/1595) into the local `stephenlclarke/container` fork so `container-compose` can progress while upstream review continues.

The feature closes the runtime half of the Docker Compose `blkio_config` path:

- `container-compose` parses Compose `blkio_config` and projects it to typed OCI block I/O data.
- `container` carries the parsed Linux-specific payload through opaque `RuntimeConfiguration.runtimeData`.
- `containerization` applies it through `LinuxContainer.Configuration.blockIO`.

Following JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), the durable upstream ask is the typed runtime bridge. The local `--blkio` parser exists only because the current plugin create path still uses command vectors and Chris George's #1595 branch exposes that validation surface.

References:

- [apple/container#1512](https://github.com/apple/container/issues/1512)
- [apple/container#1595](https://github.com/apple/container/pull/1595)
- [apple/containerization#739](https://github.com/apple/containerization/pull/739)
- Docker Compose `blkio_config`: <https://docs.docker.com/reference/compose-file/services/#blkio_config>

## Commit Tracking

- Container code commits:
  - `cce5438` in `stephenlclarke/container` (`feat(runtime): add blkio runtime data`).
  - `a41dd78` in `stephenlclarke/container` (`chore(deps): pin containerization fork`).
- Lower runtime code dependency: `apple/containerization#739`, locally carried by `stephenlclarke/containerization@integration/blkio-runtime`.
- Compose mapping code commit: `ffa2570` in `stephenlclarke/container-compose` (`feat(runtime): map compose blkio config`), not part of this Apple PR.

## Implementation Details

- Supported global `weight` and `leaf-weight`.
- Supported per-device `weight`, `leaf-weight`, `read-bps`, `write-bps`, `read-iops`, and `write-iops`.
- Accepted `device=` as either an absolute host path or a `<major>:<minor>` literal.
- Encoded parsed block I/O data into `LinuxRuntimeData`.
- Decoded runtime data in `RuntimeService.configureContainer` and converted the OCI wire model to `Containerization.LinuxBlockIO`.
- Pinned this integration branch to `stephenlclarke/containerization@integration/blkio-runtime`, which contains Chris George's `apple/containerization#739` branch.
- The local fork also carried repeatable `--blkio <option>` parsing for the existing command-vector create path; an upstream PR should drop or soften that bridge if maintainers prefer typed-only configuration.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --filter 'ParserTest/testBlockIO|RuntimeConfigurationTests/testRuntimeConfigurationWithVariant'
```

Broader validation:

```bash
swift test --filter ParserTest
git diff --check
```

## Dependency Notes

This branch intentionally depends on the local containerization fork while [apple/containerization#739](https://github.com/apple/containerization/pull/739) is open. If #739 lands upstream, the package pin should move back to `apple/containerization` at the accepted release or revision before an upstream `apple/container` PR is opened.
