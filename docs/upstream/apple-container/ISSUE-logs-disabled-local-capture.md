<!-- markdownlint-disable MD013 -->

# [Request]: Support disabled persisted local log capture

## Template

This issue draft follows `.github/ISSUE_TEMPLATE/02-feature.yml`.

## Feature or enhancement request details

Docker and Docker Compose can request that a container use the `none` logging driver for workloads where persisted stdout/stderr logs should not be retained. Docker Engine documents `--log-driver none` as making no logs available for the container, and Compose exposes the same service-level intent through `logging.driver: none` and the legacy `log_driver: none` key.

`apple/container` currently persists workload stdout/stderr to the local container bundle by default. After the typed local logging policy model is added, the next small runtime slice is to let that policy explicitly disable persisted local capture while preserving attached stdio streams for clients that are already connected to the process. `container-compose` owns translating Compose `logging.driver: none` into this typed policy.

Requested behavior:

- Add a local log storage policy value that represents disabled persisted capture.
- Keep `.local` as the default so existing containers and `container logs` behavior remain unchanged.
- When the policy is disabled, do not create a persisted raw or structured log writer for runtime stdout/stderr.
- Preserve caller-attached stdio handles so interactive or attached clients still receive process output.
- Keep Compose-specific service fan-out, prefixes, colors, and `logging.driver` validation outside `apple/container`.

Direction note: after JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), this Apple-facing slice should not depend on Apple accepting a Docker-shaped `--log-driver none` parser. The runtime behavior is useful through typed configuration alone.

Related upstream context:

- [apple/container#1752](https://github.com/apple/container/issues/1752): Compose-compatible log semantics umbrella.
- [apple/container#1591](https://github.com/apple/container/issues/1591): base log retrieval-options request.
- [apple/container#1592](https://github.com/apple/container/pull/1592): Chris George's log retrieval-options direction.
- [Docker Compose service logging](https://docs.docker.com/reference/compose-file/services/#logging): documents service-level `logging.driver` and `logging.options`.
- [Docker logging driver configuration](https://docs.docker.com/engine/logging/configure/): documents per-container `--log-driver` usage and lists `none` as a supported driver.

The local integration branch already contains this disabled-capture behavior in commit `6cbf778 feat(logs): support disabled log storage`.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
