# Pull request: persist generic container stop defaults

## Commit tracking

- Constructible commit: `8650e5d` (`feat(runtime): persist container stop defaults`)
- Separate Compose consumer: `aa1a5dab` (`feat(runtime): map stop defaults and CPU CFS resources`)
- No `apple/containerization` change is required.

## Summary

Add generic `container run/create --stop-signal` and `--stop-timeout` values,
persist them in `ContainerConfiguration`, and let an omitted later stop option
resolve to the stored value before falling back to five seconds.

## Apple-shaped boundary

This is a generic container configuration and lifecycle-default primitive. It
does not contain Compose types, Docker duration parsing, project policy, or
Windows behavior. Explicit stop signal/time options still override stored
defaults for every client.

## Code map

- `ContainerStopOptions` represents an omitted timeout as `nil`.
- `ContainerConfiguration` persists optional signal and timeout defaults with
  backward-compatible decoding.
- client flags and `Utility` write creation defaults;
  `ContainersService` resolves omitted values; `RuntimeService` supplies the
  final five-second fallback.
- parser, configuration, and staged macOS guest integration tests cover the
  creation and later-stop paths.

## Validation

Focused unit tests, five `TestCLIStop` guest cases, `make check`, and the
Container 1,042-test unit coverage gate passed locally. Compose parity against
Docker Compose V2 5.3.1 config and local dry-run mapped `SIGUSR1`/`9s` to
`--stop-signal SIGUSR1 --stop-timeout 9`. Docker Engine dry-run was skipped
only because no local daemon was available.

## Review checklist

- [ ] Replay `8650e5d` onto the current Apple base.
- [ ] Verify persisted defaults are used only when a stop caller omits them.
- [ ] Verify old saved configuration decodes with no defaults.
- [ ] Verify explicit stop options remain authoritative.

## Non-goals

Docker Compose parsing, lifecycle events, and Windows shutdown semantics.
