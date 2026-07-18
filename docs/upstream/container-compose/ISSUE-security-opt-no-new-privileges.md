# Compose compatibility gap: no-new-privileges security option

## Compose surface

`services.<name>.security_opt` with either `no-new-privileges:true` or
`no-new-privileges:false`. The equivalent `=` spellings are accepted too.

## Docker Compose V2 behavior

Docker Compose V2 preserves service `security_opt` entries in
`config --format json` and passes supported entries to the Engine container
security-option configuration. For the following local fixture, the Docker
Compose V2 configuration output retains the option unchanged:

```yaml
services:
  api:
    image: alpine:3.20
    security_opt:
      - no-new-privileges:true
```

## Previous container-compose behavior

The normalizer retained `security_opt`, but runtime validation rejected every
non-empty entry before `create`, `up`, or one-off `run` could create a service
container. The generic no-new-privileges capability was therefore unavailable
through Compose despite being representable in the local runtime.

## Ownership and minimal implementation

This requires one generic, Docker-compatible CLI/config bridge in the
Apple-shaped `container` fork and a small Compose adapter. It does not create a
Compose-specific fork API.

- `stephenlclarke/container` commit
  `8fe41fb32adcdad3520aa38ce1e9befda155bfec` adds repeatable
  `container run/create --security-opt` parsing for no-new-privileges and
  projects it to the existing process configuration.
- The existing `containerization` process model already exposes
  `LinuxProcessConfiguration.noNewPrivileges`; no `containerization` source or
  package-pin change is necessary.
- `container-compose` commit
  `99225d76440fa1852facbf7895cb0900498069d0` validates the narrow supported
  set and appends the existing generic `--security-opt` argument in both
  service and one-off command vectors.
- `container-compose` commit
  `da649c62b8e086bdb2356c2cadecbcf7df1a894c` pins the replayed Container
  commit for the tested release stack.

The fork change is limited to a generic runtime option and its existing process
configuration projection. The Compose repository owns Compose-file parsing,
validation, error wording, and command-vector rendering.

## Scope and non-goals

- Apply `no-new-privileges:true` and `no-new-privileges:false` to Linux guest
  init processes on macOS.
- Accept either colon or equals spelling, matching the generic runtime parser.
- Reject unsupported `security_opt` entries before resource creation.
- Do not claim support for SELinux labels, AppArmor profiles, seccomp profiles,
  arbitrary `security_opt` strings, or Docker's full privileged-device and
  masked-path behavior.
- Do not add Windows-specific isolation or credential surfaces.

## Expected behavior

- Docker Compose V2 and `container-compose config --format json` retain the
  no-new-privileges entry in their respective config models.
- `container-compose --dry-run up --no-start` renders
  `--security-opt no-new-privileges:true` for the service container.
- `container-compose run` renders the same generic runtime option for a
  one-off container.
- Unsupported entries such as `label:disable` fail before any runtime command
  or resource mutation.

## Upstream handoff condition

The `container` implementation is a pushed, Apple-shaped fork commit replayed
onto the current `fork/main` base. Before an upstream PR is opened, rerun its
focused parser/resource/runtime tests and `make check` on the final base; if
the fork advanced, replay only this code commit and refresh the reference.
