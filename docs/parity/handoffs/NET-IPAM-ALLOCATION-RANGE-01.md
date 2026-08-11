# NET-IPAM-ALLOCATION-RANGE-01 Handoff

## State

`Verified`. The bounded IPv4 allocation-range contract has a fresh Docker oracle and a source-matched, release-artifact candidate certificate on this MacBook Pro. It verifies one VMNet network pool with an allocation range, gateway, auxiliary reservations, service restart retention, and project teardown. It does not close advanced network and IPAM parity as a whole.

## User-visible contract

A Compose project with two services and this `ipam.config` pool must allocate dynamic IPv4 addresses from the specified `ip_range`, exclude the configured gateway and auxiliary reservations, retain a service's address through `compose restart`, and remove the project network on `compose down`:

```yaml
subnet: 192.168.200.0/24
ip_range: 192.168.200.128/25
gateway: 192.168.200.1
aux_addresses:
  reserve-in-range: 192.168.200.130
  reserve-outside-range: 192.168.200.10
```

This is intentionally one IPv4 pool only. It does not certify a deterministic cross-runtime service-to-address order, static endpoint allocation, IPv6 ranges or auxiliary addresses, multiple pools, custom drivers, global address spaces, reconciliation after controller/provider failure, namespace joins, or release-grade comparable-or-better performance.

## Docker oracle

The same-MBP reference is Docker Compose `5.4.0` with Docker Engine `29.2.1` (API `1.53`). Its marker-protected fixture and raw inspect/cleanup records are retained under `/private/tmp/container-ipam-allocation-range-release.ZgE2Ll/evidence`. Docker allocated `192.168.200.128` and `192.168.200.129`, retained `alpha` across restart, and removed the project network after `down`.

## Verified candidate certificate

The strict repository-owned Bash CLI fixture is `Tools/parity/check-compose-network-ipam-allocation-range.sh --strict`. It runs the built release Compose CLI through the matching release Container CLI, records the Docker and candidate lanes, and refuses an unmarked evidence root. The candidate allocated only from `192.168.200.128/25`, observed `alpha` at `192.168.200.129/24` and `beta` at `192.168.200.128/24`, skipped the in-range auxiliary reservation `192.168.200.130`, retained `alpha` at `192.168.200.129/24` after restart, and recorded the network as absent after `down`.

| Input | Exact identity |
| --- | --- |
| Compose source and binary | Signed `30d3017112a9b7694aaec2ec80a0cfa411e6004d`; release `compose` SHA-256 `abce539706c9f91dfaff9b533fbd056b2c7a7c84ef81ad3ad00c9d397db476b1` |
| Container behavior source | Signed `d7e5f5ddd831e0fe0cf025d606f1d2622eb6a4d2` (`fix(network): retain attachments across restart`) |
| Container focused-test checkpoint | Signed `ec286fca9bca2c4d9d732f6f898564d9f23e1eb6` (`test(network): cover retained attachment release cleanup`) |
| Container release binaries | CLI SHA-256 `39aa0a280a742a574992a7ce958c3688ff453b278c8027bea0db58deb2034168`; API server SHA-256 `4a106660a9cd1bfddb6acbe6170ba75adf139e7dcd9f1533558feca944b24faa` |
| Containerization | Signed `cfb00bbf3523079fe2ab9fb6b8e9b3504eff77e5` |
| Engine API | Signed `4949e743675f00ec102f7acacdb4e990409e383f` |
| Guest init image | Source-built `vminit:container-compose`; OCI archive SHA-256 `0c16d06e8e7142205db8cc1dd820c863f0b7c5303295a4b4d6998cc163680873` |
| Builder shim | `docker.io/library/container-builder-shim:completion-418e3c5`; OCI archive SHA-256 `d8c65304a8248b8e736752ca52a3e75ee8fe1c6339dd9de3601935d7329926ab` |

`FINGERPRINT-PREFLIGHT.json` and `FINGERPRINT-COMPLETE.json` retain all source heads, resolved dependencies, built binaries, guest input, runtime result, and disposable-root identity. Their SHA-256 values are `6c5a2b9122ed0059dc795f313f4bb0e38e5e0e37a3f6c82be53ac68f3ddc0cc1` and `7fad85c52397946949456e867ae56e67189aaac1a70bd5f53c685834f0c614c6`; every recorded tracked and untracked source-tree digest was empty. The complete record reports `candidate_status: passed`.

## Focused source proof and coverage

`swift test --enable-code-coverage --filter 'AttachmentAllocatorTest|DefaultNetworkServiceTest'` passes 31 tests in two suites at the exact Container test checkpoint. `AttachmentAllocator.swift` has 92.96% focused line coverage. The exercised cleanup paths cover retained and session-scoped attachment tracking, idempotent release, MAC and IPv6-map cleanup, and session release. `DefaultNetworkService.swift` remains 68.87% overall because it contains substantial unrelated controller logic; this is visible rather than hidden. A fabricated direct XPC release call is not valid outside a live reply-capable XPC request, so the real strict CLI certificate supplies the cross-process release route proof.

## Timing record

| Operation | Docker seconds | Candidate seconds | Interpretation |
| --- | ---: | ---: | --- |
| `up` | 0.363003 | 3.355610 | 9.24x; post-functional performance evidence |
| `restart alpha` | 10.243070 | 6.762113 | Candidate faster in this sample |
| `down` | 10.297832 | 6.451396 | Candidate faster in this sample |

These are one retained release-artifact diagnostic sample, not a counterbalanced performance matrix. They satisfy the narrow functional timing guard only and do not establish comparable-or-better programme performance.

## Remaining gaps

- IPv6 `ip_range` and auxiliary reservation behavior, including sparse allocation boundaries.
- Ordered multiple same-family pools, custom IPAM and network drivers, provider options, and default local/global address spaces.
- Static endpoint requests, concurrent allocation/exhaustion/reuse order, durable ledger persistence, controller/helper/provider crash recovery, and reconciliation.
- Custom/existing-network and namespace-join behavior, endpoint options, live guest data-plane properties, and devcontainer adoption.
- Counterbalanced release performance median/P95 evidence for the broader network matrix.

## Tracking and safe handoff

Stephen-owned [Container issue #83](https://github.com/stephenlclarke/container/issues/83) is commented and closed as completed for the restart-retention defect. The local Compose build-overlay tracker [#206](https://github.com/stephenlclarke/container-compose/issues/206) is also closed. Preserve this handoff, the marker-protected evidence root, the local Apple-shaped handoff pair, and Slack START thread `1786040469.766159`. No Apple issue, pull request, branch publication, push, hosted CI, or other upstream publication is authorised by this certificate.
