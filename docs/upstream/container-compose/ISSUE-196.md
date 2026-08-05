# Issue 196: static logs fail for an unreadable logging driver

## Steps to reproduce

Use a Compose service with `logging.driver: none`, start it, and request static history:

```sh
docker compose up --detach
docker compose logs
```

Docker Compose 5.3.1 exits successfully with an empty stream. The matched Container runtime correctly reports that the configured driver does not support reading, but container-compose previously surfaced that lower-level error and failed the command.

## Problem description

The direct Container and Engine API reader error is correct, but Compose has a narrower presentation contract. Static Compose history treats an unreadable driver as empty and continues every other readable selected service. Follow remains unsupported because it cannot produce a readable stream.

The fix must:

1. Introduce a driver-neutral Compose runtime error for unsupported history reads.
2. Map both the public Container reader category and the legacy generic unsupported category at the runtime adapter boundary.
3. Suppress that category only for static Compose history.
4. Preserve it for follow and for direct Container/Engine clients.
5. Prove a mixed readable/unreadable service selection and the live CLI fixture against Docker Compose 5.3.1.

## Environment

- **OS**: macOS 26.5.2, arm64 Mac17,9
- **Docker**: Engine 29.2.1 / Compose 5.3.1, Colima context
- **container-compose**: signed local `main` through `c7a50e28438ca0c5bd5a668d3b8e87db25c4a176`
- **Container**: signed local `upstream/logging-driver-parity` at `bfa8b361901e33bc427d5bb551d19b2a224ca3f2`
- **Containerization**: signed local `upstream/engine-linux-sandbox` at `38d9c695e7a6915e5ce45d12c893dc323a661af7`
- **Engine API**: signed local `main` at `c7973ac641fb6f6e07df1358114f36222bd9ca59`

## Tracking

- GitHub issue: [stephenlclarke/container-compose#196](https://github.com/stephenlclarke/container-compose/issues/196)
- No Apple publication is involved; synchronized upstream publication remains deferred until all programme development completes.
