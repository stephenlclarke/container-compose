# Preserve explicit empty Compose process overrides

## Summary

`services.<name>.command: []` and `services.<name>.entrypoint: []` are distinct Compose values. Docker Compose V2 preserves both in `config --format json`; an empty entrypoint removes the image `Entrypoint` while retaining the image `Cmd`.

The normalizer previously used `omitempty` slices and erased both empty-list forms. The runtime renderer therefore inherited an image entrypoint when Compose had explicitly cleared it.

## Acceptance Criteria

- Normalized Compose JSON distinguishes omitted process fields from explicit empty arrays.
- `compose config --format json` retains `"command": []` and `"entrypoint": []`.
- `entrypoint: []` emits only the generic `container run/create --clear-entrypoint` primitive.
- `command: []` remains a preserved Compose model value and does not add positional runtime arguments.
- A Docker Compose V2 fixture proves an image with `/bin/false` as `ENTRYPOINT` executes its retained `CMD` only after the entrypoint is cleared.
- The matching macOS runtime executes the same fixture when its isolated runtime test lane is enabled.

## Scope

The Compose layer owns Compose parsing, normalization and mapping. The lower fork owns only the generic, non-Compose `--clear-entrypoint` process primitive. Windows container behavior is not in scope.
