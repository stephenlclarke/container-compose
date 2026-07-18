# Compose compatibility gap: Deploy memory reservation projection

## Compose surface

`services.<name>.deploy.resources.reservations.memory`

## Docker Compose V2 behavior

Docker Compose V2 carries the Deploy resource block through configuration and,
in local mode, maps a non-zero memory reservation to Docker Engine
`HostConfig.MemoryReservation`. CPU reservation is deliberately different: it
remains scheduler metadata in local mode.

The reference implementation is intentionally narrow:

- `pkg/compose/create.go` initializes resources from service fields;
- `setReservations` then assigns a non-zero Deploy `MemoryBytes` value to
  `MemoryReservation`;
- the same function does not project Deploy CPU reservation.

Compose-go rejects a service that supplies distinct values for
`mem_reservation` and `deploy.resources.reservations.memory`; equal values are
valid. That makes the two spellings one local runtime value rather than two
independent constraints.

## Previous container-compose behavior

The normalizer accepted the Deploy reservation as local metadata but discarded
it before the typed Compose service model. Consequently `up`, `create`, and
one-off `run` omitted the runtime's existing `--memory-reservation` primitive.

## Ownership and minimal implementation

This is a Compose adapter gap, not an Apple runtime gap.

The pinned Apple-shaped forks already provide the generic primitive:

- `stephenlclarke/containerization`
  `c5ca0366d88cf77eefb857b7b3d7f2d098070bab` projects
  `memoryReservationInBytes` to OCI Linux memory;
- `stephenlclarke/container`
  `d5774583697dc239b140ae38cc79fa9259753061` carries that field through the
  runtime and exposes `--memory-reservation`.

`container-compose` therefore only normalizes the Deploy memory value into its
existing `memReservation` field. The existing create-plan validation and
runtime argument rendering remain the sole execution path. No fork source or
dependency pin changes are needed.

## Scope and non-goals

- Map non-zero Deploy memory reservations on macOS through the Linux guest
  runtime.
- Preserve CPU reservation as local scheduler metadata; do not truncate or
  invent a fractional CPU reservation primitive.
- Do not add Windows-only resource surfaces.
- Leave Deploy pids, generic-resource, and non-GPU device reservations to
  their separate runtime/scheduler work.

## Expected behavior

- `compose config --format json` exposes normalized `memReservation` byte
  count for a Deploy memory reservation.
- `compose --dry-run up` renders `--memory-reservation VALUE` for the service
  container.
- Docker Compose V2 config and dry-run remain the parity oracle; the parity
  fixture checks that CPU reservation is accepted without being projected while
  memory reservation is projected.
