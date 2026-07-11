# Runtime Resolver Files Pollute The macOS Search List

## Upstream Reference

- Existing report: [apple/container#1917](https://github.com/apple/container/issues/1917)

Do not open a duplicate issue.

## Problem

The API service writes `/etc/resolver/containerization.<domain>` with both a
`domain` and `search` directive. The resolver filename and `domain` directive
already scope queries to the runtime domain. The additional `search` directive
adds that private domain to macOS bare-hostname expansion, which can delay
unrelated lookups when the runtime DNS server is unavailable.

## Expected Behavior

- Runtime domains remain resolvable through their scoped resolver file.
- Runtime domains are not added to the host's global search list.
- Deleting and recreating a resolver file removes any legacy `search`
  directive left by an older release.

## Ownership

`container` owns host resolver generation. Compose does not need DNS-policy
workarounds for this host configuration bug.
