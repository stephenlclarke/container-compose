# Docker REST Image Mutation Oracle

## Scope and Result

The Docker REST image-mutation contract is functionally **Verified** on the
same MBP against Docker Engine 29.2.1/API 1.53 and the matched Container public
socket. The retained Bash certificate drives Docker CLI 29.7.1 without
modification and covers a pinned Linux/arm64/v8 pull, a unique secondary tag,
list/inspect identity through the native Container catalog, removal of only the
secondary tag, preservation of the source image, and Docker's exact
missing-image delete error.

This closes `POST /images/create`, `POST /images/{name...}/tag`, and
`DELETE /images/{name...}` for public, unauthenticated pulls and tag deletion.
Registry credentials, push, search, history, build/session, credential
projection, typed guest socket grants, and external-client adoption remain in
[STATUS.md](../../STATUS.md) and the
[API socket design](../non-local-volumes-advanced-mounts-api-socket-design.md).

## Pinned Oracle

| Component | Exact reference |
| --- | --- |
| Docker CLI | 29.7.1 |
| Docker Engine | 29.2.1 |
| API range | 1.44 through 1.53 |
| Platform | Linux/arm64/v8 on the same Apple-silicon MBP |
| Image | `docker.io/library/alpine:3.20` |
| OCI index | `sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc` |
| Mutation tag | `container-compose-image-mutation-contract:20260805` |

The reference resolves the selected Docker context before switching to an
isolated client configuration containing no credentials. Both lanes require
the exact Docker CLI version. The reference additionally requires the exact
Engine version, while the candidate receives an explicit isolated Unix socket.

## Verified Candidate Fingerprint

| Component | Exact value |
| --- | --- |
| container-compose certificate | `81fca6a1e8f482a6efadb4c7ee9e9dfea386ee86` |
| Container | `259878a427de7021b52e40e759d3b261150cc514` |
| Containerization | `38d9c695e7a6915e5ce45d12c893dc323a661af7` |
| container-engine-api | `4949e743675f00ec102f7acacdb4e990409e383f` |
| Provider declaration digest | `sha256:50dced5cc6e6168851d76ec49676682975fe998d57fa9469b048a6301ea8b465` |
| Disposable state-root UUID | `bcd9b30f-7c55-4d94-bff2-394fd35ee312` |
| Release archive SHA-256 | `1658dda04febf3b9db182a9124874a07502ea0f8ffb7f8b3667874df52cef239` |
| Staged Container CLI SHA-256 | `5447b59f42cc93491d73790521a5434dd2940920f1facaa3fdd2db39898572e4` |
| Staged API server SHA-256 | `e6114d2ca754992a22fd8b873d855e11a845be9877d39272c9fc36d140090ae4` |
| Staged engine gateway SHA-256 | `40ca895cc87d4e88ed3eb2b4f578510a082066605a5b68e0b0e25601fee43fa5` |
| vminit OCI archive SHA-256 | `d01d08f79ced95195e7b8073dc447769cdc8a393124ca79adcd27cf8a281da17` |
| vminit arm64 manifest | `sha256:03bfa88df6a7e4900aecf8014a4ee5cd5ba989848902b2845b01abfd2fb16a4f` |

The provider declaration advertised native `ImageCreate`, `ImageTag`, and
`ImageDelete` capabilities. The release archive was built from the exact local
Container, Containerization, and Engine API sources above. The binary embeds
the full Container and Containerization revisions; SwiftPM workspace state
independently proves that the Engine API and Containerization inputs were the
declared local paths. The isolated runtime used the exact local vminit image,
the pinned Alpine index, and one canonical marker-protected `/tmp` state root.

Container intentionally rejects a non-canonical `/private/tmp` alias for
security-sensitive persisted state because it resolves through a symlink to
`/tmp`. The certificate therefore uses the canonical resolved path; this is a
test-root requirement, not a product compatibility gap.

## Reproduce the Focused Proof

```console
make docker-rest-image-mutation-parity \
  CONTAINER_COMPOSE_CONTAINER=/path/to/exact/container \
  DOCKER_REST_LOGGING_CANDIDATE_SOCKET=/tmp/exact-state/app/docker.sock
```

Both lanes print `Docker REST image mutation contract passed`. The certificate
uses unique state and tag names, removes only the secondary tag, asserts that
the pinned source digest is unchanged, and proves the native catalog contains
the same tag before deletion and no such tag afterward.

The focused Engine API mutation tests passed with coverage enabled. Of 208
executable production lines added by the mutation commit, 194 were exercised:
**93.27% changed-line coverage**. The new mutation model/protocol file reached
100% whole-file line coverage. The shared controller reached 87.86% whole-file
line coverage while its mutation delta exceeded the 90% workflow target.

The focused Container `ContainerLogsTests` run passed all 47 tests. Its unit
instrumentation exercised 84 of 177 executable lines in the full Container
mutation delta (**47.46%**). The uncovered block is principally the concrete
native-catalog pull/unpack/tag/delete adapter; the release candidate's Docker
CLI certificate executes that exact production block end to end. This does not
claim 90% Container unit coverage: extracting an independently injectable
native image authority remains testability work, while the user-visible
contract is covered by the stronger live integration proof.

## Performance Result

Five counterbalanced cached command batches each ran pull, tag, inspect, and
remove against Docker and Container. Median batch time was 1.403093 seconds for
Docker and 1.153473 seconds for Container. The candidate was **17.79% faster**
for this sequence and therefore meets the programme's comparable-or-better
target as well as its separate 10× regression guard.

All raw observations remain visible in the
[timing TSV](docker-rest-image-mutation-timings-2026-08-05.tsv) and the
[JUnit evidence](docker-rest-image-mutation-2026-08-05.junit.xml).

## Remaining Evidence-Backed Gaps

- Non-empty Docker registry credentials are rejected before pull because the
  selected native provider does not yet implement credential transformation.
- Image push and registry authentication routes remain unimplemented.
- Search, history, build, BuildKit session, and progress-stream completeness
  remain outside this focused mutation contract.
- Digest deletion with multiple repository references is implemented but is
  not yet covered by a focused unit test or the retained public-socket Bash
  certificate.
- The concrete Container native-catalog adapter remains below the 90% unit
  coverage aim even though the release integration certificate executes it.
- Testcontainers, devcontainer, and the typed in-container socket-grant
  lifecycle remain unverified consumers.
