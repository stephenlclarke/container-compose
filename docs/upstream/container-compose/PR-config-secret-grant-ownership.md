# Compose follow-up: generated config and secret ownership

## Summary

- Honor service-level `uid` and `gid` for generated `configs.content`,
  environment-backed configs and secrets, and external config or secret data.
- Render those regular-file mounts through the fork-backed typed bind path.
- Preserve Docker Compose file-backed behavior: do not mutate the source and
  ignore grant ownership metadata on an ordinary live bind mount.

## Design

Compose keeps source policy local. It materializes generated values as it did
for mode handling, then requests ownership only for that generated regular
file. The lower runtime copies it privately at container creation, applies the
requested numeric ownership inside the guest, and mounts the copy read-only.

The snapshot is intentionally creation-time state. Changing a generated value
or ownership metadata changes the effective service fingerprint and triggers
recreation. To consume a changed file in an existing container, recreate it.

## Dependency handoff

- `stephenlclarke/containerization` main:
  `86593b23c77d03d7d170631bc2bfe4dd114fc6c1`
  ([PR #8](https://github.com/stephenlclarke/containerization/pull/8))
- `stephenlclarke/container` main:
  `568097c88366e55ed3ee36847ca2b4e879a5f867`
  ([PR #20](https://github.com/stephenlclarke/container/pull/20))
- Apple-shaped handoff docs:
  [containerization](../apple-containerization/PR-file-mount-ownership.md)
  and [container](../apple-container/PR-file-mount-ownership.md)

Neither change was pushed to an Apple remote.

## Validation

- Generated owned config mounts render `type=bind` with numeric `uid` and
  `gid`.
- Invalid ownership values fail before runtime side effects.
- File-backed configs and secrets continue to render as unchanged read-only
  `--volume` binds even when the Compose grant contains ownership metadata.
