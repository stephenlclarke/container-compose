# Docker Compose CLI Surface Parity

This check compares the command paths and documented long options exposed by
the local `container-compose` binary with an installed Docker Compose v2
reference binary. It measures CLI discoverability, not runtime behavior.
Runtime support remains authoritative in [STATUS.md](../../STATUS.md).

## Run The Check

Run only the CLI surface comparison:

```sh
make docker-compose-cli-surface-parity
```

Run every maintained behavioral and CLI parity target:

```sh
make docker-compose-parity
```

The CLI target writes the exact compared versions, command paths, option paths,
documented differences, and unexpected differences to:

```text
.build/parity/compose-cli-surface.md
```

Strict mode fails when either binary is unavailable, a help path cannot be
read, or any difference is not present in the allowlist.

## Comparison Rules

The harness recursively reads root, command, Bridge, and Bridge transformation
help. It compares command paths and long-option names while ignoring prose,
spacing, aliases, and terminal color. A green local option can still have a
narrower runtime mode; [STATUS.md](../../STATUS.md) records those partial
semantics separately.

## Documented Differences

The machine-readable source of truth is
[`Tools/parity/compose-cli-surface.allowlist`](../../Tools/parity/compose-cli-surface.allowlist).
A successful strict run permits only these differences:

| Scope | Local-only surface | Reason |
| --- | --- | --- |
| Root command | `help` | Swift ArgumentParser exposes help as an explicit command; Docker Compose exposes help flags without listing a root `help` command. |
| Root command | `convert` | The current Docker documentation includes `convert`, while the installed standalone reference binary used by the harness does not list it. |
| Root command | `alpha` | The current Docker documentation includes the alpha aliases, while the installed standalone reference binary accepts alpha help without listing the namespace. |
| Root option | `--verbose` | `container-compose` keeps this for diagnostics; the reference binary accepts it for version output without listing it in root help. |

Do not add an allowlist entry merely to make the check pass. Confirm the current
Docker documentation and binary behavior, then document why the difference is
intentional. Use the generated report for exact evidence rather than copying a
versioned snapshot into this file.

## Related Documentation

- [STATUS.md](../../STATUS.md): every tracked Compose file, service,
  Dockerfile/build, command, and long-option support indicator.
- [BUILD.md](../../BUILD.md): contributor validation and aggregate parity
  commands.
- [`check-compose-cli-surface.sh`](../../Tools/parity/check-compose-cli-surface.sh):
  comparison implementation and environment overrides.
