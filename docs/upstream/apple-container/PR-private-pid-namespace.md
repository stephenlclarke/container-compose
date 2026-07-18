# Pull request: accept explicit private PID namespace mode

> [!IMPORTANT]
> Sign and verify all commits before opening the upstream pull request. File the
> linked feature request before proposing this feature.

## Type of Change

- [x] New feature
- [ ] Breaking change
- [x] Documentation and test update

## Motivation and Context

Container already uses a private PID namespace by default, but rejected an
explicit generic request for that existing behavior. Docker Compose V2 accepts
`pid: private`; the generic CLI should accept the equivalent `--pid private`
without changing runtime behavior.

## Changes

- Constructible Container commit: `a3672cb`
  (`feat(runtime): accept private PID namespace mode`).
- Separate Compose V2 parity consumer: `6df979b1`
  (`feat(runtime): map Compose private PID namespace`), with hermetic adapter
  test coverage in `f851a86f` (`test(runtime): isolate namespace adapter tests`).
- Accept `container run|create --pid <host|private>` and reject other values.
- Preserve `hostPIDNamespace == false` for `private`, so the existing
  Containerization private PID namespace remains unchanged.
- Update generic `container run --help`, parser, command-vector, and daemon CLI
  integration coverage.

## Apple-shaped boundary

This is a minimal generic Container parser/configuration change. No Compose or
Docker model enters Container source. It adds no Windows behavior, host-Linux
path, cross-container PID sharing, or new lower-runtime API.

## Testing

- [x] Focused parser and run/create command tests passed (271 tests).
- [x] `container run --help` exposes `--pid <pid>` with the accurate `host or
  private` description.
- [x] The local runtime CLI integration passed after rebuilding the daemon,
  persisting private PID mode and confirming the guest PID proc surface.
- [x] Compose Docker Compose V2 config/dry-run parity passed against Docker
  Compose `5.3.1`; no Docker daemon was available, so the harness skipped only
  Engine dry-run confirmation.

## Compatibility and risks

Absent and `private` values preserve existing behavior. `host` continues to
select the sandbox VM PID namespace; `private` retains the container's private
PID namespace. The parser rejects namespace-sharing forms rather than silently
selecting a mode it cannot provide.

## Review checklist

- [ ] Replay `a3672cb` on the intended Apple base.
- [ ] Verify `container run --help` includes `--pid <pid>` with both modes.
- [ ] Verify omission and `private` retain `hostPIDNamespace == false`.
- [ ] Keep Docker/Compose types, Windows and host-Linux behavior, cross-container
  PID sharing, and lower-runtime API changes out of scope.
