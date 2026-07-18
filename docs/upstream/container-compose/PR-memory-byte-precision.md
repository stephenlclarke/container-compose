# Pull request: retain Compose hard-memory limits byte-for-byte

## Summary

- Preserve byte-granular `services.<name>.mem_limit` values end to end.
- Correct generic `container run/create --memory` parsing to avoid MiB
  truncation for explicit values and defaults.
- Add normalizer and Docker Compose V2 config/dry-run parity coverage.
- Update `STATUS.md` to show byte-accurate hard memory limits as supported.

## Apple-shaped implementation boundary

The fork change is a narrow, generic resource-parser correction. It is
Compose-agnostic and continues to use the existing byte-based guest runtime
resource model.

| Repository | Commit and responsibility |
| --- | --- |
| `stephenlclarke/containerization` | No source change. Existing resource configuration uses bytes. |
| `stephenlclarke/container` | `75753499d74a66da9c3aaeea8be7f0a05e413464`: retain generic memory values in bytes in parsing, defaults, help, and unit tests. |
| `stephenlclarke/container-compose` | `c94dc4f42cd6377af2ed01ae3312a77962661447`: add exact-byte normalizer and Docker Compose V2 parity coverage and update the gap register. |

The `container` commit must be rebased or replayed onto current upstream before
submission because its local branch is behind `fork/main`. Keep that PR limited
to the generic resource parser, model projection, command reference, and unit
coverage; do not add a Compose-aware API to the fork.

## Implementation details

- `Parser.resources` now reads a generic memory string directly as bytes.
- Explicit `--memory` and the default resource value follow the same
  byte-preserving path.
- Compose already normalizes `mem_limit` to its exact decimal byte value;
  `Tools/parity/check-compose-memory-byte-precision.sh` protects that contract
  across Docker Compose V2 config output and local Compose dry-run rendering.
- The fixture deliberately uses 200 MiB plus one byte, which exposes any
  accidental integral-MiB conversion.

## Docker Compose V2 parity contract

For this fixture:

```yaml
services:
  api:
    image: alpine:3.20
    mem_limit: 209715201b
```

- Docker Compose V2 `config --format json` contains `mem_limit: 209715201`.
- `container-compose config --format json` contains `memLimit: "209715201"`.
- `container-compose --dry-run up --no-start api` renders the exact generic
  `--memory 209715201` argument.
- When Docker Engine is available, the parity script also verifies Docker
  Compose V2 accepts the fixture in `--dry-run up`. Its config and local
  command-vector checks remain deterministic without Docker Desktop or Colima.

## Validation

Completed locally for this slice:

```sh
cd /Users/sclarke/github/container
swift test --disable-automatic-resolution --filter ParserTest
make check
make coverage-unit

cd /Users/sclarke/github/container-compose
make build
DOCKER_COMPOSE=.build/docker-reference-test/docker-compose \\
  CONTAINER_COMPOSE=.build/debug/compose \\
  Tools/parity/check-compose-memory-byte-precision.sh --strict
make DOCKER_COMPOSE_REFERENCE=.build/docker-reference-test/docker-compose \\
  docker-compose-memory-byte-precision-parity
make coverage-check
git diff --check
```

The Container parser suite passed 189 tests and its full unit suite passed 940
tests. The Compose coverage gate passed with 91.35% Swift and 85.50% Go
coverage. Docker Engine dry-run confirmation was unavailable on the local Mac;
Docker Compose V2 config parity and the local Compose dry-run assertion passed.

## Review checklist

- [ ] The `container` change remains generic and Compose-agnostic.
- [ ] The fork commit is rebased onto the current upstream base before opening
  the Apple handoff PR.
- [ ] The Compose adapter continues to send the generic byte count unchanged.
- [ ] The test value remains non-MiB-aligned to catch truncation.
- [ ] Docker Compose V2 config and local Compose dry-run parity pass on the
  final stack.

## Non-goals

- Windows resource controls or isolation behavior.
- Fractional CPU quota and the remaining cgroup CPU, swap, and OOM controls.
- Changing `containerization` or introducing a Compose-aware fork API.
