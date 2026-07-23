# Pull request handoff: close Phase 4 metadata, state, and events

## Summary

- Add one aggregate Docker Compose V2 parity target for the completed macOS
  Phase 4 boundary.
- Record the exact Apple-shaped implementation commits and ownership split.
- Keep unavailable Docker Engine and Linux-host-only states/actions as explicit
  runtime primitive gaps.
- Correct the release documentation so the temporary Phase 5 Builder exception
  is bounded to pre-Phase-5 `0.7.x` through `0.9.x` and fails closed at
  `0.10.0`.

## Type of change

- [ ] Bug fix
- [ ] New runtime feature
- [x] Test and release hardening
- [x] Documentation update

## Implementation

`make docker-compose-phase4-parity` depends on all six strict Phase 4 targets.
Make resolves the shared build and Docker Compose reference prerequisites once,
then stops on the first failed fixture. No production adapter or lower-fork
behavior changes in this closure commit.

The phase implementation remains split by ownership:

| Capability | Generic lower layer | Compose adapter |
| --- | --- | --- |
| OCI annotations | [`containerization` `9109cbb`](https://github.com/stephenlclarke/containerization/commit/9109cbb8dab85917475f2ab3cecdbee797e2c0ad); [`container` `9a75157`](https://github.com/stephenlclarke/container/commit/9a75157a0c4ed1497bfb6b4ce8f43f6f1c25f0c8) | [`container-compose` `eed2b309`](https://github.com/stephenlclarke/container-compose/commit/eed2b309b8ce460b7eb4c07578a2a3b959e5f786) |
| Exposed ports | [`container` `2f7b6e4`](https://github.com/stephenlclarke/container/commit/2f7b6e4d207027f5b44a27070e0baddbbe42fb76) | [`container-compose` `c09f5e3`](https://github.com/stephenlclarke/container-compose/commit/c09f5e3e0bbedff40e63a8782847dec625203c40) |
| Empty process overrides | [`container` `9350500`](https://github.com/stephenlclarke/container/commit/93505008b130822065b89a6c5d610b9b6fa80122) | [`container-compose` `3ce98a9`](https://github.com/stephenlclarke/container-compose/commit/3ce98a933d99a281b1ef054ad33467f580d95b94) |
| Created/exited projection | Existing runtime timestamps | [`container-compose` `e056f2a`](https://github.com/stephenlclarke/container-compose/commit/e056f2a66d15dd58904e1c6a90245035989be2e2) |
| `up --exit-code-from` | Existing wait/stop/delete primitives | [`container-compose` `1d03db4`](https://github.com/stephenlclarke/container-compose/commit/1d03db47e6ab32b31743029c8b52e027c6617623) |
| Terminal events | [`container` `7ed57b1`](https://github.com/stephenlclarke/container/commit/7ed57b18a7dbadddea21007d0a2c17d0ae399fa0) | [`container-compose` `4a43965`](https://github.com/stephenlclarke/container-compose/commit/4a4396544200419011b5afc5eb896821a0a059bc) |
| Exec events | [`container` `735e8aa`](https://github.com/stephenlclarke/container/commit/735e8aaec538a1d043d97525074e4175ae1ac10f) | [`container-compose` `3c7998e`](https://github.com/stephenlclarke/container-compose/commit/3c7998e3ea12ecf757b57d0c9b338d18b513725f) |

## Validation

Run on macOS with Docker Compose V2 5.3.1:

```console
make docker-compose-phase4-parity
make check
make coverage-check
CONTAINER_COMPOSE_LIVE=1 make docker-compose-phase4-parity
```

The complete release gate remains authoritative for the assembled live stack.
Hosted CI, Quality, CodeQL, and exact-revision Sonar must pass before Current
and stable publication.

## Compatibility and risk

The aggregate target is additive. It changes no command, Compose file, runtime
API, or stored state. Its failure mode is intentionally conservative: a broken
reference fixture or any Phase 4 regression blocks the phase boundary.

Docker lifecycle states `dead`, `restarting`, and `removing`, plus OOM, explicit
restart, rename, resize, update, interactive attach, and detach events remain
out of scope until the generic runtime exposes observable primitives. Windows
behavior and Linux-host-only telemetry are not macOS parity targets.

## Reviewer handoff

- [x] The change is minimally invasive and Compose-owned.
- [x] All referenced lower-fork commits are generic and Compose-free.
- [x] Docker Compose V2 fixture checks remain the parity authority.
- [x] Remaining unsupported behavior is explicit.
- [x] Issue and pull request handoffs identify the exact code commits.
