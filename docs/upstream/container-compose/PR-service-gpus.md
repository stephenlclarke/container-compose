# Pull Request

## Summary

- Map service `gpus` and Deploy generic GPU reservations to the fork-backed runtime `--gpus` primitive.
- Preserve Deploy GPU reservations as typed normalized service data instead of generic unsupported Deploy fields.
- Validate the supported Apple virtio-gpu subset before resource creation.
- Add focused Swift and Go coverage plus a Docker Compose V2 parity script/Makefile target.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose users expect `gpus: all` and generic Deploy GPU reservations to work when the runtime exposes GPU support. The matched `stephenlclarke` runtime lane now carries a narrow Apple virtio-gpu primitive, so the Compose layer can implement Docker-compatible generic GPU mapping while keeping vendor/native GPU passthrough rejected with clear diagnostics.

Upstream references:

- [apple/container#1511](https://github.com/apple/container/issues/1511)
- [apple/containerization#480](https://github.com/apple/containerization/issues/480)
- [apple/containerization#569](https://github.com/apple/containerization/pull/569)
- Compose service `gpus`: <https://docs.docker.com/reference/compose-file/services/#gpus>
- Compose Deploy device reservations: <https://docs.docker.com/reference/compose-file/deploy/#devices>

## Implementation Details

- Adds `deployGPURequests` to the normalized Swift service model.
- Updates the Go normalizer to split Deploy device reservations into generic GPU requests and non-GPU unsupported Deploy fields.
- Adds `runtimeGPUArguments(service:)` to convert service/deploy GPU requests to canonical Docker CLI-style `--gpus` values.
- Validates supported backend semantics before any image, network, volume, or container side effects.
- Renders repeatable `--gpus` arguments in service create/run command vectors.
- Adds `Tools/parity/check-compose-gpus.sh`, `make docker-compose-gpus-parity`, Swift unit tests, Go normalizer tests, and parity script syntax/help checks.

## Docker Compose Compatibility Notes

Supported on the fork-backed integration stack:

- `gpus: all`, `count: 1`, `device_ids: ["0"]`, and equivalent `driver: virtio` requests.
- Deploy device reservations with the generic `gpu` capability.
- Dry-run `up`, `create`, and one-off `run` rendering of `--gpus`.

Rejected before side effects:

- Vendor drivers such as `nvidia`.
- Driver options.
- Multiple GPUs.
- Non-zero GPU device IDs.
- Extra capabilities such as `compute` or `utility`.
- Non-GPU Deploy device reservations.

## Validation

```bash
go test ./...
swift test --filter ComposeNormalizerTests
swift test --filter 'upMapsServiceGPUsAllToRuntime|upMapsDeployGPUReservationsToRuntime|upRejectsUnsupportedGPUDriversBeforeCreatingResources|upRejectsNonGPUDeployDeviceReservationsBeforeCreatingResources|runMapsServiceGPURequestsToRuntimeArguments'
bash -n Tools/parity/check-compose-gpus.sh
Tools/parity/check-compose-gpus.sh --help
make docker-compose-gpus-parity
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes.
- [x] I updated relevant upstream handoff docs so stale GPU-blocked language is removed.
- [x] I recorded upstream issue and PR references.
- [x] I added focused tests and parity validation.
- [x] I avoided pushing changes to Apple remotes.
