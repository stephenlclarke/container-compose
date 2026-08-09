# Issue 195: logging parity ignores matched local packages

## Steps to reproduce

On the designated MBP, with the signed logging implementation retained locally because its matched Container revision is intentionally unpublished, run:

```sh
./Tools/parity/check-compose-signal-log-reliability.sh --strict
```

The Docker runtime scenarios pass. The script then calls `swift test --disable-automatic-resolution`, but the package manifest has no identity-preserving local dependency override. SwiftPM attempts to fetch Container revision `2a79b4553a342e33411666a88ad20ccd2ce46551` from the project remote and cannot check it out because that coordinated revision is not published.

## Problem description

The documented MBP-only parity target cannot complete against the exact matched local stack. Its runtime binary path is configurable, but its embedded Swift unit gate silently uses the remote package graph instead of the selected local Container and Containerization repositories.

The fix must:

1. Add explicit path-based Container and Containerization dependency overrides without changing the default remote graph or package identity, and pass the matched Engine API path through the Container package graph.
2. Pass the existing `CONTAINER_STACK_REPO`, `CONTAINERIZATION_STACK_REPO`, and `CONTAINER_ENGINE_API_STACK_REPO` selections through the parity target to the Compose build and embedded unit gate.
3. Prove the Docker lane and matched Container lane with the same clean command.
4. Leave no SwiftPM mirror or editable-package metadata behind.

## Environment

- **OS**: macOS 26.5.2, arm64 Mac17,9
- **Swift**: local Swift 6.3 toolchain
- **Docker**: Engine 29.2.1 / Compose 5.3.1, Colima context
- **container-compose**: signed local `main` through `c7a50e28438ca0c5bd5a668d3b8e87db25c4a176`
- **Container**: signed local `upstream/logging-driver-parity` at `bfa8b361901e33bc427d5bb551d19b2a224ca3f2`
- **Containerization**: signed local `upstream/engine-linux-sandbox` at `38d9c695e7a6915e5ce45d12c893dc323a661af7`
- **Engine API**: signed local `main` at `c7973ac641fb6f6e07df1358114f36222bd9ca59`

## Tracking

- GitHub issue: [stephenlclarke/container-compose#195](https://github.com/stephenlclarke/container-compose/issues/195)
- No credentials, tokens, private data, or Apple publication are involved.
