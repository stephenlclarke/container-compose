# Pull Request: Keep Runtime DNS Domains Scoped

## Summary

- Stop writing a `search` directive to runtime resolver files.
- Keep the `domain`, loopback nameserver, and port directives unchanged.
- Assert that generated resolver content cannot pollute global search domains.

## Upstream Reference

- Fixes [apple/container#1917](https://github.com/apple/container/issues/1917).
- No overlapping open pull request was found.

## Commit Tracking

- Fork commit: `160035f` in `stephenlclarke/container`.
- The commit is intentionally separate from imported upstream changes.

## Validation

```sh
swift test --disable-automatic-resolution --filter HostDNSResolverTest
make check
make test
```

The change is intentionally limited to generated content. Existing files are
not silently mutated; an administrator can remove and recreate an affected
domain with `container system dns delete` and `container system dns create`.
