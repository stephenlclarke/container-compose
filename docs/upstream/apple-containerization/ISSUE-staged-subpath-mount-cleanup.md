# Bug: staged volume-subpath mounts leave a Container guest directory busy

## Summary

Containerization stages a block-volume subpath as a bind mount under
`/run/container/<id>/subpaths/<index>`. During container stop it unmounted the
OCI rootfs but left that staging bind and its backing volume mount active. The
guest agent then could not recursively remove the container root, returning
`EBUSY` from `deleteProcess`.

## Reproduction on macOS

Run a Compose project with a local volume mounted using `volume.subpath`, then
bring it down. The image-volume parity fixture exercises this through a
pre-created `nested` directory. Before the correction, cleanup can fail with a
busy path such as:

```text
/run/container/<id>/subpaths/9
```

The guest filesystem cleanup is generic Containerization behavior used by the
macOS Virtualization runtime; it is not a Compose-specific workaround.

## Expected behavior

After stopping the initial process and unmounting its rootfs, Containerization
must release each staged subpath bind before unmounting its backing volume. The
guest container root must then be removable without `EBUSY`.

## Ownership and boundary

`LinuxContainer` owns staging and teardown of the generic block filesystem
mounts. Compose only expresses a typed `volume-subpath` mount and must not
retry, detach, or delete guest paths itself.

## Commit tracking

- `93d77103c9a1ada25fd825478b2643e296810dc2` —
  `fix(mounts): release staged subpath mounts`.

## Validation expectations

- Unit coverage records rootfs, staged-bind, and backing-volume unmount order.
- Run the source-matched Compose image-volume parity fixture on macOS and
  confirm `down --volumes` removes the subpath service cleanly.
