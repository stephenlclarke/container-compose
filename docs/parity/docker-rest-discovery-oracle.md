# Docker REST Discovery Oracle

## Scope and Result

The Docker REST discovery contract is functionally **Verified** on the same MBP against Docker Engine 29.2.1/API 1.53 and the matched Container public socket. The retained Bash certificate drives Docker CLI 29.7.1 without modification and covers `docker version`, created/exited/running container rows, default/all listing, label/status/name filters, exactly one matching native Container object for every Docker row, Docker-compatible health summaries, and exact cleanup.

This closes only `GET /version` and `GET /containers/json`. It is not a full Docker REST or `use_api_socket` claim. Image, auth, push, build/session, archive, events, exec, credential projection, typed guest socket grants, handoff, external clients, and the remaining generated route ledger are tracked in [BACKLOG.md](../project/BACKLOG.md), [issue #270](https://github.com/stephenlclarke/container-compose/issues/270), and the [API socket design](../architecture/non-local-volumes-advanced-mounts-api-socket-design.md).

## Pinned Oracle

| Component | Exact reference |
| --- | --- |
| Docker CLI | 29.7.1 |
| Docker Engine | 29.2.1 |
| API range | 1.44 through 1.53 |
| Platform | Linux/arm64 on the same Apple-silicon MBP |
| Image | Preloaded `docker.io/library/alpine:3.20` |

The version response must contain the Docker top-level system-version fields and report API 1.53, minimum API 1.44, Linux, and arm64. The list response must expose Docker's summary shape. A workload without a configured health check reports `Health` as `{ "Status": "none", "FailingStreak": 0 }`; a string is wire-incompatible with Docker CLI 29.7.1.

## Verified Candidate Fingerprint

| Component | Exact value |
| --- | --- |
| container-compose | `046ab3d477b1275e8a8d30489526365c626aec54` |
| Container | `43654bd9f36f7c3bb4f57609efa4a488db0b8324` |
| Containerization | `38d9c695e7a6915e5ce45d12c893dc323a661af7` |
| container-engine-api | `34299b1a391ba28cdf5911177ee4b0623ff12491` |
| Provider fingerprint | `sha256:ce1f145890310418bc21426f556d967af4c1daae4f34bb8f1517248e432f1c4a` |
| Disposable state-root UUID | `9fe5f57f-f8e7-4fc7-911d-28813411b6a8` |
| Release archive SHA-256 | `35d240dbc3e1f9d2b185a9d4977b03ce9d5fa08ee0198e347cb381d10d026722` |
| Container CLI SHA-256 | `968315a1785a5a1c6643ef0deab62f28efe323ea38fe3b889ceb5342fce61750` |
| API server SHA-256 | `9cc37e6fee2a5e20ed24ba58cff5f27e7e445517dcce1b4cbf29c1ef7ed6a237` |
| Engine gateway SHA-256 | `57c5e5f6a5895ee057cf804ff97b1c3335532813d63d35f47b4c84139aa0cb45` |
| vminit archive SHA-256 | `96aa5555efa6414338ca8b51818e32671c7a4e3f1b7b6ca5073a394ab6d914a2` |
| vminit manifest | `sha256:03bfa88df6a7e4900aecf8014a4ee5cd5ba989848902b2845b01abfd2fb16a4f` |
| Alpine arm64 manifest | `sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d` |

The provider declaration advertised `engine.route.SystemVersion` and `engine.route.ContainerList`. The release build, its embedded source/dependency revisions, verified init image, preloaded Alpine image, isolated state, public socket, and focused proof therefore belonged to one exact fingerprint.

## Reproduce the Focused Proof

```console
make docker-rest-discovery-parity \
  CONTAINER_COMPOSE_CONTAINER=/path/to/exact/container \
  DOCKER_REST_LOGGING_CANDIDATE_SOCKET=/tmp/container-engine-$(id -u)/docker.sock
```

The oracle and candidate lanes both printed `Docker REST discovery contract passed`. The focused Engine API route/query tests and Container projection/provider-session tests passed before the release build. Container issue [#73](https://github.com/stephenlclarke/container/issues/73) records the incompatible health-summary defect, exact live failure, regression evidence, and completed closure.

## Timing and Remaining Performance Gap

The 5 August 2026 checkpoint recorded one monotonic whole-fixture sample per lane: Docker completed in 1.28 seconds and Container in 3.14 seconds, a 2.45× candidate/reference ratio. Both lanes exercised identical lifecycle assertions and cleanup, while the candidate additionally proved native-authority identity. The result passes the programme's explicit less-than-10× regression guard but is not comparable or better; discovery/lifecycle startup overhead remains in the programme performance gap until a counterbalanced release sample is inside the declared noise band. Raw values are retained in the [TSV](docker-rest-discovery-timings-2026-08-05.tsv) and [JUnit](docker-rest-discovery-2026-08-05.junit.xml) evidence.
