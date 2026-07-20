# Pull request: retain Compose local network attachable metadata

## Summary

- Preserve top-level `networks.<name>.attachable` in the Compose model and `config` output.
- Accept the field for the macOS vmnet local-network path.
- Add Docker Compose V2 configuration parity and live Apple standalone-attachment coverage.
- Update Status and the focused release-gate target.

## Commit tracking

- Compose code: the signed `feat(network): retain attachable metadata` slice commit. The relevant implementation is `Tools/compose-normalizer/main.go`, `Sources/ComposeCore/NormalizedProject.swift`, and `Sources/ComposeCore/ComposeOrchestratorValidation.swift`; its unit and parity evidence is co-located in the corresponding test files and `Tools/parity/check-compose-network-attachable.sh`.
- Apple/container and Containerization prerequisites: none. The existing local vmnet network already accepts standalone attachment.

## Implementation details

The compose-go normalizer exposes its existing `NetworkConfig.Attachable` value through the typed Compose model. Validation no longer rejects that field. The create request intentionally remains unchanged: Apple vmnet only supplies local networks, and standalone `container run --network` attachment is already available there regardless of the Swarm/overlay restriction Docker documents for `attachable`.

This stays wholly in the Compose layer. It adds no Compose terminology, Docker flag, or policy to either Apple fork.

## Docker Compose compatibility notes

Docker Compose V2 preserves `attachable: true` in normalized configuration. The explicit manual-attachment gate is relevant to Swarm overlay networks. Those networks and Windows behavior are outside the supported macOS local runtime, while the equivalent local standalone-attachment capability is exercised directly by the parity test.

## Validation

```console
cd Tools/compose-normalizer && go test ./...
swift test --filter 'ComposeNormalizerTests.normalizesComposeFileThroughComposeGo|ComposeOrchestratorTests.upAcceptsAttachableProjectNetworksAndRejectsRemainingUnsupportedOptionsBeforeSideEffects'
make docker-compose-network-attachable-parity
make test
make coverage-check
make check
```

The parity script requires Docker Compose V2 config output and verifies `container compose --dry-run up`. The aggregate `make docker-compose-parity` starts the isolated Apple runtime and additionally verifies that a standalone `container run --network` joins the created vmnet network.

## Compatibility and risk

- Existing projects retain their behavior; omitted and `false` values remain absent in normalized output, matching compose-go/Docker Compose output.
- `attachable: true` is not a claim of Swarm or overlay support.
- Container-facing service DNS, custom network drivers, and shared network namespaces remain separate Phase 2 gaps.

## container-compose checks

- [x] The change is limited to one Compose compatibility field.
- [x] No Apple fork change is required.
- [x] Docker Compose V2 configuration parity is covered.
- [x] The live macOS vmnet standalone-attachment path is covered by the aggregate parity gate.
