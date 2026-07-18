# Feature request: accept explicit private PID namespace mode

## Feature or enhancement request details

`container` already creates a private PID namespace when no host PID mode is
requested, but its generic CLI rejected the explicit `private` mode accepted by
Docker Compose V2. This prevented a macOS user from expressing the same
default-preserving intent through `container run|create --pid private`.

Container commit `a3672cb` accepts `--pid host|private`, keeps
`ContainerConfiguration.hostPIDNamespace` false for `private`, and forwards the
unchanged private default to Containerization. Compose commit `6df979b1` maps
the standard `pid: private` field by omitting a redundant generic runtime flag.

This is a small generic CLI/configuration compatibility improvement. It adds no
Docker or Compose type in Container source, Windows behavior, host-Linux path,
cross-container PID sharing, or new Containerization primitive.

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
