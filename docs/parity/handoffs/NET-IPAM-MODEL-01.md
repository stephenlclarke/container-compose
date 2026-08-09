# NET-IPAM-MODEL-01 Handoff

## State

`Verified` as a narrow static source-model certificate. It proves that Docker Compose-compatible advanced top-level IPAM values survive `container compose config` and `container compose convert`; it does not enable, certify, or benchmark runtime network creation.

## User-visible contract

A Compose file may declare IPAM driver/options, ordered IPv4 and IPv6 pools, subnets, allocation ranges, gateways, named auxiliary addresses, and explicit or absent `enable_ipv4` and `enable_ipv6` flags. Docker Compose 5.4.0 preserves that source model through `config`. Container Compose now preserves the same requested information through both public static commands, using its documented camelCase normalized model, without contacting or mutating the Engine.

## Exact proof

The marker-protected reference root `/private/tmp/container-net-ipam-model-reference.VR8XD8` contains the isolated `compose.yaml`, `.container-net-ipam-model-reference-root`, Docker Compose 5.4.0 `config --format json` result, candidate `config` and `convert` results, and the candidate preflight/certificate records. The reference fixture SHA-256 is `f3c1e97c81357adbd1abe85f1ee6a30386fa3f2c934479bdc93820e59cffc33b`; Docker's static output SHA-256 is `45ab2874cbe083eda2fec8999fac6e123741541fa3cef5e58a839460ecb65e14`; both candidate public outputs have SHA-256 `4fa5d912777abe146c5d9018d2ed2dfa6797ec111eb23ace2c961b77d3991e74`; and the exact candidate binary SHA-256 is `8b60c9188e13f543142a8289f5ca3734ef8270df3f75e87c6149c25bad2ce083`.

The retained `Tools/parity/check-compose-network-ipam-model.sh --strict` certificate invokes Docker Compose `config`, then the built candidate's `config` and `convert`, and asserts the complete public model plus the current runtime-preflight boundary. Its final exact-binary pass takes 1.957022334 seconds from one `time.monotonic_ns` process. That is a debug static-model smoke duration, not comparable-or-better release performance evidence.

The focused Go regression `TestNormalizeRetainsLosslessIPAMSourceModel` passes with `normalizeIPAM` at 100.0% focused line coverage. The exact local-overlay Swift regression `ComposeNormalizerTests/normalizerPreservesSourceOrderedAdvancedIPAMModel` passes; instrumented coverage reports both executable additions in `NormalizedProject.swift` covered (100.0%). `bash -n`, ShellCheck, and the harness help path pass.

The static build overlays only the exact local Container and Containerization package paths. An attempted local Engine API overlay fails before compilation because it reintroduces unavailable historical Container revision `2a79b4553a342e33411666a88ad20ccd2ce46551`; that API is outside this source-only contract. The successful overlay build restores `Package.resolved` to its checked-in SHA-256 `a61f450629fb45e6e39c66ef725bc390cb413ee61fad60ce518d04952c786ef5`.

## Implementation

`Tools/compose-normalizer/main.go` now copies the complete compose-go IPAM source model into ordered normalized pools and preserves `EnableIPv4`. `Sources/ComposeCore/NormalizedProject.swift` exposes a typed `ComposeNetwork.IPAM` model with ordered pools and named auxiliary addresses. The existing singular IPv4/IPv6 runtime fields remain as compatibility adapters; they are not used to reconstruct the source model.

The existing `unsupportedFields` values stay intact as a runtime-preflight guard until the versioned provider/capability work in `NET-WP-06`. They no longer imply data loss: `config` and `convert` retain the requested values while `up` refuses a request that the current vmnet adapter cannot apply safely.

## Remaining boundary

Custom network/IPAM providers, disabled-IPv4 runtime behavior, allocation-range and auxiliary-address application, durable leases, multiple-pool reconciliation, endpoint semantics, runtime data-plane proof, migration/security proof, and comparable-or-better release performance remain queued in `NET-WP-02` through `NET-WP-09`. No Apple upstream issue, pull request, or publication is created by this Compose-only static projection.

Stephen-owned [issue #199](https://github.com/stephenlclarke/container-compose/issues/199) records the discovered source-loss defect. It closes as completed only after this exact local checkpoint is signed; creating and closing the tracker does not publish source changes.

## Documentation disposition

`STATUS.md`, the advanced-network design, and the parity ledger now distinguish verified source-model preservation from the remaining runtime gap. README, BUILD/install guidance, public CLI help, stack refs, package pins, and release material are unchanged because this adds no user-facing option, package, runtime dependency, or release artifact.

## Safe resumption

Keep the marker-protected root and signed local checkpoint. Do not rerun broad runtime, security, migration, or performance gates for this source-only contract; select a distinct queued runtime contract after polling Slack. The completed slice START thread is `1786011892.286669`.
