# [Request]: Add a typed local container logging policy model

## Template

This issue draft follows `.github/ISSUE_TEMPLATE/02-feature.yml`.

## Feature or enhancement request details

Docker Compose services can declare local logging behavior through `logging.driver`, `logging.options`, and the legacy `log_driver` / `log_opt` keys. `container-compose` can translate local-development logging choices such as `json-file`, `local`, `none`, `max-size`, and `max-file`, but the runtime first needs a stable configuration surface where per-container logging policy can be stored and passed to the runtime writer.

The first upstream-sized step is a typed model only:

- Add `ContainerLogConfiguration` to `ContainerResource`.
- Add `ContainerConfiguration.logging` with a default value that preserves current local stdio capture.
- Keep the model focused on local capture policy, not Compose formatting.
- Keep service names, colors, prefixes, replica ordering, and Compose driver compatibility decisions outside `apple/container`.
- Preserve backward compatibility by decoding containers without a `logging` key as the default policy.

This model gives later, smaller PRs a place to attach:

- disabled persisted capture for a local `none` policy;
- local retention fields populated by direct API callers or `container-compose`;
- writer-level local rotation;
- static rotated replay.

Direction note: after JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), Docker logging driver aliases and `logging.options` parsing should stay in `container-compose`. The Apple-facing ask is the typed local capture and retention policy model plus runtime writer behavior.

Related upstream context:

- [apple/container#1752](https://github.com/apple/container/issues/1752): Compose-compatible log semantics umbrella.
- [apple/container#1591](https://github.com/apple/container/issues/1591): base log retrieval-options request.
- [apple/container#1592](https://github.com/apple/container/pull/1592): Chris George's log retrieval-options direction.
- [Docker Compose service logging](https://docs.docker.com/reference/compose-file/services/#logging): documents service-level `logging.driver` and `logging.options`.
- [Docker `json-file` logging driver](https://docs.docker.com/engine/logging/drivers/json-file/): documents local retained log options such as `max-size` and `max-file`.
- [Docker `local` logging driver](https://docs.docker.com/engine/logging/drivers/local/): documents local logging behavior.

The local integration branch already contains this model in commit `e41e630 feat(logs): add container logging policy model`.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
