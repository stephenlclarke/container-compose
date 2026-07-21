# Preserve `services.expose` as container metadata

## Compose surface

`services.<name>.expose`

## Docker Compose V2 behavior

Docker Compose V2 preserves service `expose` entries in `config --format json`.
They describe ports available to peers but do not create a host listener;
`services.ports` is the independent host-publishing mechanism. Docker Compose
accepts individual ports, inclusive ranges, and optional TCP/UDP protocols.

## Gap

The normalizer already retained `service.expose`, but the runtime create plan
and generic Container configuration had no exposed-port metadata channel. The
value was therefore silently lost before a container was created.

## Required behavior

- Preserve `service.expose` through the typed `ContainerServiceCreatePlan`.
- Render repeatable generic `container --expose` options when creating a
  service container.
- Never synthesize `--publish` for `expose` metadata.
- Pin the generic macOS runtime primitive that persists and validates exposed
  ports.
- Prove normalized configuration and dry-run arguments against a checked-in
  Docker Compose V2 fixture.

## Scope

The compose project owns this Docker Compose projection. The matching
`apple/container` change is a generic macOS metadata surface with no Compose
imports; `containerization` needs no change because OCI Runtime Spec has no
exposed-port field. Windows behavior and Docker Engine host-port emulation are
out of scope.
