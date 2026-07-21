# Preserve Docker-shaped terminal lifecycle events

## Compose surface

`container compose events [--json] [--since TIME] [--until TIME] [SERVICE...]`

## Docker Compose V2 behavior

For a selected service, Docker Compose V2 reports a signal delivery as `kill`,
the init-process result as `die`, and removal as `destroy`. Its JSON stream
keeps the events scoped to the selected service, removes internal Compose
labels, and carries signal or exit-code attributes where Docker observed them.

## Gap

The macOS runtime previously exposed only generic `stop` and `delete` lifecycle
records. The Compose adapter forwarded every runtime action, so it could not
emit Docker-shaped terminal actions and would show two removal records if a
generic runtime added `destroy` while retaining `delete` for compatibility.

## Required behavior

- Pin the minimal generic runtime event addition that emits `kill`, `die`, and
  `destroy` alongside existing generic events.
- Preserve Docker-shaped `kill`, `die`, and `destroy` actions in Compose JSON
  and text output, including their public attributes.
- Suppress the generic `delete` event only in the Compose renderer, so removal
  appears once as Docker's `destroy` without breaking generic event consumers.
- Record an explicit Docker Compose V2 fixture that starts a selected service,
  kills it, and removes it before asserting the terminal action set.
- At the time of this terminal slice, keep the command partially supported
  until OOM, automatic restart, rename, resize, update, attach/detach, and
  exec events are available. Subsequent exec work now provides
  `exec_create`/`exec_start`/`exec_die`, and automatic restart is correctly
  represented as `die` then `start`.

## Scope

This is a macOS Compose adapter and generic runtime-event change. It neither
implements Docker Engine, a Docker socket, Linux-only OOM reporting, nor
Windows behavior. The generic fork contains no Compose import or protocol.
