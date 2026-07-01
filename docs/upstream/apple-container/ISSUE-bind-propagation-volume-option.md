# Preserve bind propagation volume options

## Feature or Enhancement Request Details

`apple/container` should keep accepting and preserving bind propagation strings supplied through the existing short `--volume` option slot, for example:

```bash
container run --volume /host:/container:ro,rslave IMAGE
```

This is useful to higher-level tooling that already renders short volume arguments and relies on `Filesystem.options` to reach OCI mount options. The Apple-facing behavior is not a Compose-specific parser feature; it is the generic guarantee that short volume mount options such as `rslave` are retained and passed through.

## Current behavior

The short `--volume` parser already splits the third field into `Filesystem.options`. That means options such as `ro,rslave` are preserved without a new runtime primitive. The gap found while implementing Compose bind propagation was missing regression coverage for this behavior.

## Expected behavior

- `Parser.volume("/host:/container:ro,rslave")` returns a filesystem mount with options `["ro", "rslave"]`.
- The parsed options continue to flow through container creation as mount options.
- No Docker Compose policy or Compose-specific naming should be added to Apple/container.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
