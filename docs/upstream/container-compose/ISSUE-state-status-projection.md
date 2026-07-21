# Project Docker `created` and `exited` service states

## Compose surface

`container compose ps [--all] [--status STATE] [--filter status=STATE]`

## Gap

The macOS runtime exposes `RuntimeStatus.stopped` for both a container that has
never been started and one whose init process has finished. It already records
`startedDate` in the same snapshot, but Compose forwarded only `stopped`.
Consequently, `ps` could not distinguish Docker Compose V2's `created` state
from `exited`, and it treated `--status exited` as a generic `stopped` alias.

## Required behavior

- Project a stopped snapshot with no `startedDate` as Docker `created`.
- Project a stopped snapshot with a `startedDate` as Docker `exited`, retaining
  existing exit metadata.
- Apply the same rule to direct `ContainerClient` and CLI JSON discovery.
- Keep `ps --status created` and `--filter status=exited` independent.
- Do not make `stopped` an `exited` alias: Docker Compose V2 accepts it but
  returns no matching service for this lifecycle.
- Record the exact V2 lifecycle with a checked-in Compose fixture.

## Scope

This is a Compose presentation layer correction for macOS. It uses the
existing `ContainerSnapshot.startedDate` and does not add Docker state names,
Compose metadata, Windows behavior, or Linux-specific runtime logic to either
Apple fork.
