# Decode Docker image config exposed ports

## Summary

- Add optional `exposedPorts` to `ContainerizationOCI.ImageConfig`.
- Decode and encode the Docker image config `ExposedPorts` object.
- Add focused OCI image config tests covering round-trip and Docker JSON decode behavior.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker image config metadata can include `ExposedPorts`, keyed as `port/protocol`. Compose Bridge uses inspected image exposed-port metadata when enriching a Compose model before running transformer images. The lower runtime package should expose this as generic image config data so higher layers do not need raw JSON workarounds.

This is not a Compose-specific API. It simply preserves Docker-compatible image config metadata already present in local images.

## Commit Tracking

- Lower image config code commit: `dcde0cd` in `stephenlclarke/containerization` (`feat(oci): decode Docker exposed ports`).
- Container resource projection commit: `380ff28` in `stephenlclarke/container` (`feat(image): expose config metadata`).
- Compose Bridge runtime code is tracked in `docs/upstream/container-compose/PR-compose-bridge-cli.md`.

## Implementation Details

- Added `CodingKeys.exposedPorts = "ExposedPorts"`.
- Added `public var exposedPorts: [String: [String: String]]?`.
- Added an initializer argument defaulting to `nil`.
- Left validation and semantic interpretation to higher layers because this field records image metadata, not a runtime port-publish policy.

## Testing

```bash
swift test --filter OCITests/config --no-parallel
```

## Compatibility Notes

The field is optional and defaults to `nil`, so existing callers keep their current behavior. Generated JSON only changes when callers set or decode exposed-port metadata.
