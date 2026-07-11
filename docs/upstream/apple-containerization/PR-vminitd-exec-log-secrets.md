# Pull Request: Redact Vminitd Exec Process Configuration

## Summary

- Replace full OCI process interpolation with a static debug message.
- Attach only container and exec identifiers as structured metadata.
- Add a regression test that constrains the allowed logging metadata.

## Upstream Reference

- Fixes [apple/containerization#518](https://github.com/apple/containerization/issues/518).
- No overlapping open pull request was found.

## Commit Tracking

- Fork commit: `f17ec69` in `stephenlclarke/containerization`.
- The commit is intentionally separate from other local fixes.

## Validation

```sh
make check
make test
make init
make integration
```

The test is Linux-only because `ManagedContainer` is guest code. `make init`
must rebuild the guest image before integration testing so the VM does not use
a stale `vmexec` or `vminitd` binary.
