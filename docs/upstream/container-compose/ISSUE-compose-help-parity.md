# Compose compatibility gap: command HELP support markers

## Surface

`container compose --help`, `container compose COMMAND --help`, and the
Compose-layer `container compose help` extension.

## Problem

The command HELP output advertised several partially implemented commands as
fully supported, and did not expose the supported Compose-layer `help`
command. That made HELP inconsistent with the documented runtime limits and
the command behavior it is intended to describe.

`container help compose` cannot dispatch into a plugin: the outer `container`
CLI reports `compose` as an unknown command. The plugin can, however, intercept
`container compose help`; retaining that explicit extension gives users a
discoverable Compose entry point without claiming outer-CLI behavior that does
not exist.

## Required behavior

- Root HELP lists `help` as supported and describes it as a Compose-layer
  extension.
- Every command whose known runtime behavior remains incomplete is marked
  partially supported, with a concise, behavior-specific limitation.
- `container compose help` returns the same root Compose help as
  `container compose --help`.
- Docker-compatible `--help` and `-h` remain available for all commands.

## Ownership and scope

This is entirely a `container-compose` presentation and documentation fix. It
requires no Apple runtime primitive and no fork changes. It is macOS-safe; no
Windows-specific behavior is introduced.

## Validation

The Swift HELP unit tests, built-plugin CLI smoke test, and strict CLI surface
parity script verify the rendered support colors, limits, `help` command, and
the documented Docker Compose differences.
