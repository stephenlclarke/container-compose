<!-- markdownlint-disable MD013 -->

# fix(build): build source-checkout init images safely

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

SwiftPM returns `version: "unspecified"` for a branch dependency as well as a local edit. `install-init.sh` should build a matching init image for source-backed stacks, but it must not modify SwiftPM's read-only `.build/checkouts/containerization` checkout in place.

This matters for runtime APIs that span the host and guest, including the process-metadata route used by `container top` and `container compose top`. A source-backed `container` build can contain the host-side API while the booted guest still runs an older `vminitd` unless the init image is built and loaded from the same `containerization` source.

## Implementation Details

- Add `CONTAINERIZATION_INIT_SOURCE_PATH` so stack and release automation can select the exact `containerization` checkout used for the build.
- Add `CONTAINER_INIT_IMAGE_NAME` so isolated stack and parity automation can select the same init image reference used by the runtime configuration.
- Keep the existing `version: "unspecified"` SwiftPM check as the automatic source-backed dependency signal.
- Build writable local edits in place.
- Copy read-only source-control checkouts to a temporary writable directory before running `make init`.
- Save the init image to a unique temporary archive, load it into the configured container app root, and remove temporary files on exit.
- Quote resolved dependency paths and the `cctl` executable.

## Commit Tracking

- Implementation:
  `b478439e81c3ceddd58ef4be65d4c948bc1fa4f1` in
  `stephenlclarke/container` (`fix(build): build source-checkout init images
  safely`) and `d82fc5c24d48fffe2f48c8144642ab6fcf5299e0` in
  `stephenlclarke/container` (`fix(build): clean copied init sources`).
- Matched init-image reference implementation:
  `d03f81b4968d9f33914db1d77e00ce9f43178d00` in
  `stephenlclarke/container` (`build(init): install matched vminit image
  refs`).
- Lower runtime build knob:
  `d8b9585a9855b1c0958d423a2d08b564eb6f8626` in
  `stephenlclarke/containerization` (`build(init): parameterize vminit image
  reference`).

## Testing

```bash
bash -n scripts/install-init.sh
CONTAINERIZATION_INIT_SOURCE_PATH=/Users/sclarke/github/containerization \
  CONTAINER_INIT_IMAGE_NAME=vminit:container-compose \
  APP_ROOT=/tmp/container-init-test \
  make init-block
make check
make integration
```

The `container-compose` runtime harness writes a current isolated config with the matched init image reference, starts the runtime against that config, then builds and installs the same init image before running live Compose parity checks.

## Compatibility Notes

Released, versioned dependencies keep their existing behavior unless `CONTAINERIZATION_INIT_SOURCE_PATH` or `CONTAINER_INIT_IMAGE_NAME` is explicitly supplied. Writable local edits still build directly. Read-only source-control dependencies build from a temporary copy so the checkout stays immutable while the runtime gets a matching guest init image.
