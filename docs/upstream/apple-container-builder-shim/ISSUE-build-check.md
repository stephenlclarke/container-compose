# Build checks should validate Dockerfiles without exporting images

## Problem

The builder shim currently treats every solve as an image-producing build.
Callers need a validation mode that runs the Dockerfile frontend checks while
leaving exporters empty, so linting cannot unpack, tag, or push an image.

## Requested Shape

- Accept a typed `check` solve option through the existing metadata channel.
- Invoke the Dockerfile frontend lint operation with the same build arguments,
  target, platform, resolver, named contexts, labels, SSH mounts, and secrets as
  a normal solve.
- Return lint diagnostics through the existing progress and error streams.
- Do not configure image exporters or create export archives in check mode.
- Keep the feature generic to builder validation; Compose owns its command-line
  selection and post-build policy.

## References

- Docker Compose added `build --check` in
  [docker/compose#12765](https://github.com/docker/compose/pull/12765), resolving
  [docker/compose#12749](https://github.com/docker/compose/issues/12749).
- The dependent `apple/container` API and CLI draft is
  [PR-container-build-check.md](../apple-container/PR-container-build-check.md).

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
