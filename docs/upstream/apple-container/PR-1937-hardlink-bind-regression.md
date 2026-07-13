# Pull Request: Cover Non-Root Reads From Hard-Linked Bind Mounts

## Type Of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation And Context

[apple/container#1937](https://github.com/apple/container/issues/1937)
reports intermittent `EACCES` failures when a non-root Linux guest reads a
read-only directory bind mount containing host hard links. The current source
stack needs durable integration coverage for that reported boundary without
claiming that a passing run resolves an intermittent runtime race.

This proposal complements, rather than replaces,
[apple/containerization#665](https://github.com/apple/containerization/pull/665).
That change handles a related single-file mount case by sharing its parent
directory. This change exercises directory bind-mount behavior and leaves live
mount semantics intact.

## What Changed

- Add a `container run` integration test that creates 16 readable host files
  and 16 hard links in a temporary directory.
- Mount that directory read-only with `type=bind` into Alpine running as UID
  `1024`.
- Read every entry and archive the mounted directory, so guest file opens and
  directory traversal both fail the command on `EACCES`.
- Keep the test generic to `apple/container`; no Compose policy or copied
  bind-mount fallback is introduced.

## Commit Tracking

- Container code: `e0034f4fb4794c0b605540591fba8888b540fde4` in
  `stephenlclarke/container`
  (`test(mounts): cover non-root hard-link bind reads`).
- Lower runtime code: not required.
- Compose handoff documentation: this document in
  `stephenlclarke/container-compose`.

## Testing

- [x] Tested locally
- [x] Added or updated tests
- [x] Added or updated docs

Focused validation:

```bash
make integration \
  CONCURRENT_FILTER='TestCLIRunCommand/testRunCommandNonRootHardlinkBindMount' \
  SERIAL_FILTER='^$'
```

The controlled source-stack validation passes this test. Because the upstream
report is intermittent, the test is regression coverage and not evidence that
the underlying runtime race is fully resolved.

## Compatibility Notes

The test verifies a standard Docker-shaped bind mount and does not alter
runtime behavior. It protects non-root guest reads of hard-linked directory
contents while retaining the host-backed, live bind-mount contract that Compose
expects.

## References

- [apple/container#1937](https://github.com/apple/container/issues/1937)
- [apple/containerization#509](https://github.com/apple/containerization/issues/509)
- [apple/containerization#665](https://github.com/apple/containerization/pull/665)
