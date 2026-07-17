# Support long-form image mounts and `image.subpath`

## Summary

Enable Docker Compose long-form `type: image` mounts, including
`image.subpath`. The normalizer preserves the image reference and optional
directory, and the runtime renderer emits the Docker-shaped typed mount:

```text
--mount type=image,source=<image>,destination=<target>,readonly,image-subpath=<directory>
```

## Runtime contract

The paired `stephenlclarke/container` fork resolves an existing local OCI
image, unpacks its selected platform snapshot if necessary, and projects that
immutable snapshot through the existing generic block-mount path. Image mounts
are always read-only. If present, the subpath stays inside the image root via
Containerization's secure `openat2(RESOLVE_IN_ROOT)` staging.

## Scope

- Preserve `type: image`, source, target, and `image.subpath` from Compose Go
  through `ComposeMount`.
- Render image mounts as an explicit read-only `container --mount` argument.
- Reject malformed internal mount models that put `imageSubpath` on another
  mount type.
- Update the parity ledger and pin the merged `container` backend revision.

## Deliberately out of scope

- Pulling a missing image-mount source. The source must already exist in the
  local image store; service-image pull policy remains separate.
- Writable image mounts, bind subpaths, `npipe`, and cluster mounts.
- Pushing any change to Apple-owned remotes.

## Validation

- Compose-Go normalizer coverage preserves `imageSubpath` and no longer marks
  image mounts as unsupported.
- Orchestrator coverage verifies typed rendering and malformed-model rejection.
- Full Compose validation runs after the fork pin refresh.

## Fork handoff

- `stephenlclarke/container` PR #22: Docker-compatible parser, local image
  lookup, platform snapshot resolution, and secure subpath transport.

The backend change is deliberately Apple-shaped and independently reviewable;
this Compose slice owns only Compose normalization and policy.
