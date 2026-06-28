# Support named build builders

## Summary

`container build --builder NAME` should build through the requested BuildKit builder instance, and `container builder start/status/stop/delete --builder NAME` should manage that same instance.

Docker Compose and Buildx expose named builder selection. The Apple-shaped local primitive is to keep the existing default builder unchanged while allowing extra builder containers to be addressed by name.

## Expected Behavior

- Omitting `--builder`, passing an empty value, or passing `default` uses the existing `buildkit` builder container.
- Passing `--builder NAME` uses `buildkit-NAME`.
- Builder lifecycle commands accept the same `--builder NAME` option.
- Existing default-builder behavior and configuration remain unchanged.

## Compose Dependency

This primitive lets `container-compose` forward Docker Compose's `build --builder NAME` option without hosting builder state in the plugin.
