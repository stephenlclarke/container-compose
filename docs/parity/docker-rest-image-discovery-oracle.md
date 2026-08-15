# Docker REST Image Discovery Oracle

## Scope and Result

The Docker REST image-discovery contract is functionally **Verified** on the
same MBP against Docker Engine 29.2.1/API 1.53 and the matched Container public
socket. The retained Bash certificate drives Docker CLI 29.7.1 without
modification and covers `docker images`, `docker image inspect`, a normalized
registry-qualified image reference, Docker's exact missing-image error, and
one matching object in Container's native image catalog.

This closes only `GET /images/json` and `GET /images/{name...}/json`. Image
mutation, pull, push, search, history, auth, build/session, credential
projection, typed guest socket grants, and external-client adoption remain in
[BACKLOG.md](../project/BACKLOG.md), [issue #270](https://github.com/stephenlclarke/container-compose/issues/270), and the
[API socket design](../architecture/non-local-volumes-advanced-mounts-api-socket-design.md).

## Pinned Oracle

| Component | Exact reference |
| --- | --- |
| Docker CLI | 29.7.1 |
| Docker Engine | 29.2.1 |
| API range | 1.44 through 1.53 |
| Platform | Linux/arm64 on the same Apple-silicon MBP |
| Image | Preloaded `docker.io/library/alpine:3.20` |
| OCI index | `sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc` |
| arm64 manifest | `sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d` |

The list projection retains the OCI index identity, display tag, creation time,
container count, labels, and size fields. Inspect selects the host platform and
returns the index descriptor, arm64/v8 configuration, root filesystem layer,
repository tag/digest, and Docker-shaped missing-image response. Exact, short,
tag, digest, index-ID prefix, and normalized registry-qualified lookups are
covered by focused tests.

## Verified Candidate Fingerprint

| Component | Exact value |
| --- | --- |
| container-compose certificate | `e0b68e9f847badffc806d3c5e327a3475342d855` |
| Container | `056dd09be9d4dc552763e2d90c0d43527528d807` |
| Containerization | `38d9c695e7a6915e5ce45d12c893dc323a661af7` |
| container-engine-api | `c1c4d2e906b880379025d0e750f75deadfff4854` |
| Engine API test checkpoint | `88c68cb567b614ac460b9d3761cf833790eedaed` |
| Provider declaration digest | `sha256:2bcddc829a4b5ed6bc4c81e1e50d3bd6bff6949e43d20d0d1254a5f342d72f71` |
| Disposable state-root UUID | `1526caa1-e0f9-4b5f-bafa-f12e9f7eebc1` |
| Release archive SHA-256 | `64875fb3e1e740a3325be8c38c273b2a16f9b210bb57ec63f6e03e1a698742ca` |
| Container CLI SHA-256 | `32ad305ea7e4f9412e939abef22da202e6d4704a006fb112c9fcc3ca828d231f` |
| API server SHA-256 | `fe770a57154f743352abb08fefbd12aceaa6f2c2da2d08d8fc964860b365f116` |
| Engine gateway SHA-256 | `c7f0a8380c6c47fb67275572d6cceee0cd673a99d47a5b9159955f927723385f` |
| vminit archive SHA-256 | `96aa5555efa6414338ca8b51818e32671c7a4e3f1b7b6ca5073a394ab6d914a2` |

The provider declaration advertised `engine.route.ImageList` and
`engine.route.ImageInspect`. Its embedded Container and Containerization
revisions, source graph, signed release archive, verified init image, preloaded
Alpine index, isolated state, public socket, and focused proof belonged to one
immutable build. The declaration's Engine API version remains the package
release `0.3.5`; the exact locally resolved source revision and gateway binary
digest above remove that metadata ambiguity for this certificate.

## Reproduce the Focused Proof

```console
make docker-rest-image-discovery-parity \
  CONTAINER_COMPOSE_CONTAINER=/path/to/exact/container \
  DOCKER_REST_LOGGING_CANDIDATE_SOCKET=/tmp/container-engine-$(id -u)/docker.sock
```

Both lanes print `Docker REST image discovery contract passed`. The focused
Engine API controller/router tests and Container projection, host-platform,
inventory-cache, and provider tests passed before the release build. Engine API
issue [#19](https://github.com/stephenlclarke/container-engine-api/issues/19)
retains the normalized-reference routing defect and its closure evidence.

The affected Engine API logging/router module run passed all 30 tests with
coverage enabled. Across the 111 executable production lines added by the two
image-discovery commits, 101 were exercised: **90.99% line coverage**. The new
discovery backend reached 100% whole-file line coverage and the shared router
reached 94.29%; the shared controller's whole-file result was 87.43%, while its
image-discovery delta was 90.74%. Issue
[#20](https://github.com/stephenlclarke/container-engine-api/issues/20)
records the stale assertion that this coverage run exposed and the signed test
fix.

## Performance Result

Five counterbalanced 20-command batches were measured after the native image
inventory and content-addressed metadata cache were warm. Median list time was
0.49 seconds for Docker and 0.65 seconds for Container (24.5 versus 32.5 ms per
invocation). Median inspect time was 0.48 versus 0.66 seconds (24 versus 33 ms).
The largest observed candidate delta was 9 ms per invocation.

For this process/XPC-dominated micro-contract, comparable means within the
larger of 20% or 10 ms per invocation; the absolute floor prevents scheduler
noise from dominating sub-50-ms operations. Both operations pass that declared
band. Container is comparable, not better, and the ratios remain visible in
the [raw TSV](docker-rest-image-discovery-timings-2026-08-05.tsv) and
[JUnit evidence](docker-rest-image-discovery-2026-08-05.junit.xml).

## Remaining Evidence-Backed Gaps

- Container reports the selected platform's compressed content size in the
  list and inspect views. Docker's list may report a larger uncompressed image
  size, so exact list `Size` accounting is not yet closed.
- `SharedSize` remains `-1`; Container does not calculate shared layer usage.
- `Metadata.LastTagTime` is zero because the native image catalog does not
  persist tag timestamps.
- `all` and `containerd-snapshotter` cannot expose intermediate or dangling
  manifests that the native catalog does not retain.
