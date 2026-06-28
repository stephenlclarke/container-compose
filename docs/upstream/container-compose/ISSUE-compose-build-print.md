# Support `compose build --print`

## Summary

`container compose build --print [SERVICE...]` should print an equivalent Buildx bake file for the selected build graph and exit without invoking `container build`.

The plugin already maps the supported local build subset to `container build`, including build args, cache hints, labels, target stages, platforms, pull/no-cache flags, push, and dependency expansion. The remaining Compose-side gap is the render-only `--print` path: it should reuse the same service selection and validation, but produce deterministic bake JSON instead of performing build or push side effects.

## Acceptance Criteria

- `container compose help build` shows `--print` as supported.
- `build --print` accepts selected services and `--with-dependencies` using the same build graph as `build`.
- Output includes a `group.default.targets` list and a `target` map keyed by service name.
- Target entries include context, Dockerfile or inline Dockerfile, args, labels, tags, target stage, build secrets, cache entries, platforms, pull/no-cache flags, and output mode when those values are present.
- CLI `--build-arg KEY=VALUE` entries override file args, and `--build-arg KEY` resolves from the normalized project environment or process environment when available.
- `--push` renders `type=registry` for explicit service images and keeps generated local image tags as `type=docker`.
- The command produces no `container build` or image push side effects.
- Existing unsupported Compose build fields still fail clearly before output.
- Focused unit tests cover output shape, dependency expansion, arg merging, side-effect avoidance, inline Dockerfile rendering, parser behavior, and CLI help support.
- A compose.yml/Dockerfile integration smoke proves the command renders bake JSON through the plugin binary.

## Notes

This is a Compose-side render path. It does not require new apple/container or containerization APIs.
