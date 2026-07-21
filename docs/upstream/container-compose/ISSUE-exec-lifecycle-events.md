# Preserve Docker-shaped exec lifecycle events

## Compose surface

`container compose events [--json] [--since TIME] [--until TIME] [SERVICE...]`

## Docker Compose V2 behavior

For a selected service, Docker Compose V2 reports an exec process as
`exec_create: COMMAND`, `exec_start: COMMAND`, and `exec_die`. Its JSON stream
carries `execID` on every exec record and the terminal `exitCode` on
`exec_die`, scopes the record to the selected service, and removes private
Compose labels.

Docker's automatic restart policy is separate from explicit restart. A
container that restarts automatically emits `die` followed by `start`; Docker
does not emit a `restart` event action for that policy transition.

## Gap

The generic macOS runtime now has the process and event primitives needed to
publish Docker-shaped exec records, but Compose needed to pin that exact source
revision, prove that its existing thin event adapter preserves the public
action and metadata, and correct the help/status text that had incorrectly
listed automatic restart and exec actions as unavailable.

## Required behavior

- Pin the minimal generic runtime commit that emits `exec_create`,
  `exec_start`, and `exec_die` for a user-created process.
- Preserve the action spelling, `execID`, exit code, and ordinary public
  attributes through Compose JSON rendering while removing private labels.
- Add a checked-in Docker Compose V2 fixture that executes `exit 23` and
  validates the three action records and attributes.
- State that automatic policy restart is `die` followed by `start`, not an
  unavailable restart action.
- Keep the command partially supported until explicit restart, OOM, rename,
  resize, update, attach, and detach actions have macOS implementations.

## Scope

This is a macOS Compose integration and generic-runtime event projection. It
does not implement Docker Engine, a Docker socket, Windows behavior, or
Linux-only OOM event telemetry. The generic fork contains no Compose import or
protocol, and Compose adds no runtime-specific event vocabulary of its own.
