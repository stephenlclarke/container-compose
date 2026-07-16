# Pull request: support Compose network link-local IPs

## Summary

- Stop classifying `link_local_ips` as unsupported.
- Validate each value before Compose creates resources.
- Render each value as a matched `--network NAME,address=VALUE` option.
- Pin Container and Containerization to the merged supplemental-address work.
- Update the parity ledger and exercise `up` and one-off `run` mappings.

## Motivation and context

The Compose Specification allows operator-managed addresses rather than only
RFC link-local ranges. The Compose layer therefore preserves the declared IP
and delegates CIDR policy to the compatible runtime bridge.

References:

- <https://docs.docker.com/reference/compose-file/services/#link_local_ips>
- <https://cos.googlesource.com/third_party/docker/+/refs/tags/v25.0.7/libnetwork/endpoint.go>

## Implementation details

Compose rejects commas to protect its delimiter-based runtime option and
rejects unspecified or malformed addresses before resource creation. It does
not add a second prefix to bare values: the runtime bridge uses Docker's `/16`
IPv4 and `/64` IPv6 defaults. Native runtime callers may retain an explicit
prefix through the separate generic attachment API.

## Commit tracking

- Containerization backend: `e70999db4f09f5408a2429739f08f98c55e33d16`
  merged as `a7fbf5b29a410e80e1226854670670a18a9fb07b`.
- Container bridge: `678e331f13145a0be608d4dd4dbae295d48e4946` merged as
  `4281d878fb91b22f778510ae68d55f9a67365fe9`.
- Compose mapping: `feat/network-link-local-ips` until this pull request is
  merged.

## Validation

```sh
cd Tools/compose-normalizer && go test ./...
swift test --filter ComposeOrchestratorTests --disable-automatic-resolution -Xswiftc -warnings-as-errors
make check
make test
```

## Handoff status

No Apple-owned remote has been pushed. The two Apple-shaped drafts are ready
for maintainer review; the Compose mapping remains local to this repository.
