# Preserve Compose OCI annotations separately from labels

## Compose surface

`services.<name>.annotations`

## Docker Compose V2 behavior

Docker Compose V2 accepts service annotations as a mapping or list and preserves them in `config --format json`. Annotations are OCI runtime metadata, not labels: the same key may occur in both maps with different values.

## Gap

The normalizer already preserved annotations, but the Compose renderer collapsed them into `container --label` arguments. That altered their meaning and made a same-key label/annotation invalid even though Docker Compose accepts it.

## Required behavior

- Preserve service annotations independently from labels through the typed create plan and CLI rendering paths.
- Render repeatable generic `container --annotation key=value` options.
- Allow the same key in `labels` and `annotations` without replacement or conflict.
- Continue to validate annotation keys before resources are created.
- Confirm normalized YAML behavior against Docker Compose V2 using a checked-in Compose fixture.

## Scope

Compose owns the Compose-specific projection. `container` and `containerization` expose only a generic OCI annotation primitive. Windows behavior is out of scope; this is a macOS OCI runtime implementation.
