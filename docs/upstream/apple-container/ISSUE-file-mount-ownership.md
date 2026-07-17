# Feature request: expose owned regular-file mount snapshots

## Summary

`apple/container` needs a narrow CLI/API bridge for the generic lower-runtime
owned-file mount primitive. The bridge must accept numeric ownership only for
regular-file `type=bind` sources and pass structured metadata to the runtime.

## Proposed behavior

- Accept `uid` and `gid` on `--mount type=bind`.
- Validate each value as an unsigned 32-bit integer.
- Reject directories and other non-regular bind sources when ownership is
  requested.
- Forward the metadata to the existing filesystem configuration rather than
  handling file contents, copying, or Compose policy in this layer.

## Ownership boundary

The lower runtime owns snapshot creation and guest-side ownership changes.
`apple/container` owns parser validation and filesystem-model mapping.
`container-compose` owns Compose source selection: generated files may request
ownership; file-backed Compose grants remain ordinary live binds.

## References

- Lower-runtime handoff:
  [ISSUE-file-mount-ownership.md](../apple-containerization/ISSUE-file-mount-ownership.md)
- Related directory bind limitation:
  [apple/container#1937](https://github.com/apple/container/issues/1937)
