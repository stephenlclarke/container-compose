# Support long-form `volume.subpath`

## Summary

Enable Docker Compose long-form `volume.subpath` for named and inherited
volumes. The normalizer preserves the requested directory and the runtime
renderer emits Docker's standard typed mount form:

```text
--mount type=volume,source=<volume>,destination=<target>,volume-subpath=<directory>
```

## Runtime contract

The paired `stephenlclarke/container` and `stephenlclarke/containerization`
forks provide the narrow backend primitive. The volume root is mounted
privately in the guest; the requested existing directory is resolved below it
with `openat2(RESOLVE_IN_ROOT)`, then bind-mounted for the OCI runtime. This
rejects traversal, symlink escape, missing paths, and non-directory subpaths.

## Scope

- Preserve `volume.subpath` from Compose Go through `ComposeMount`.
- Render it for normal, anonymous, and discovered external volume mounts.
- Preserve read-only mode on the typed mount.
- Keep `volume.nocopy` accepted as before.
- Update the parity ledger to mark `volume.subpath` supported.

## Deliberately out of scope

- Creating the requested directory; Docker requires it to exist first.
- `image.subpath`, bind subpaths, `npipe`, and cluster mounts.
- Pushing the fork-backed runtime implementation to Apple-owned remotes.

## Validation

- Compose-Go normalizer coverage preserves `volumeSubpath` and no longer
  reports it as unsupported.
- Orchestrator coverage verifies `up` emits the typed Container mount.
- The Container and Containerization handoff documents cover the dependent
  backend parser, transport, and secure guest staging work.

## Fork handoff

- `stephenlclarke/containerization` PR #9: secure guest mount primitive.
- `stephenlclarke/container` PR #21: Docker-compatible parser and runtime
  projection.

Both changes are intentionally Apple-shaped, independently reviewable, and
remain in Stephen-owned forks pending upstream review.
