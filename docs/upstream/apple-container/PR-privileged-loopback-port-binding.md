# Pull request: bind privileged loopback host ports on macOS

## Summary

Allow a non-root macOS user to publish a host port below 1024 to an explicit
IPv4 or IPv6 loopback address. Bind the wildcard address macOS permits and
restrict it to the interface that owns the requested loopback address.

Fixes [apple/container#1985](https://github.com/apple/container/issues/1985).

## Apple-shaped boundary

- This is a generic macOS socket-forwarding primitive with no Compose policy.
- `IP_BOUND_IF` and `IPV6_BOUND_IF` are wrapped once in SocketForwarder.
- `RuntimeService` resolves the requested address once and passes an optional
  interface constraint to the existing TCP or UDP forwarder.
- High ports, wildcards, and non-loopback addresses retain their direct path.

## Code map

- `Sources/Services/RuntimeLinux/Server/HostPortBinding.swift`: resolves an
  explicit low loopback request to an interface-scoped wildcard listener.
- `Sources/Services/RuntimeLinux/Server/RuntimeService.swift`: applies the
  resolved address and interface.
- `Sources/SocketForwarder/SocketBoundInterface.swift`: native option wrapper.
- `Sources/SocketForwarder/TCPForwarder.swift` and `UDPForwarder.swift`:
  optional constraint accepted without changing existing callers.
- `Tests/ServicesTests/RuntimeLinuxTests/HostPortBindingTests.swift`: seven
  low/high, address-family, and assignment cases.
- `Tests/SocketForwarderTests/*ForwarderTest.swift`: real scoped listeners.
- `Tests/IntegrationTests/Run/TestCLIRunCommand.swift`: non-root live port 80.

## Testing

- [x] `make check`
- [x] Seven resolution and four forwarder tests
- [x] 1,131 instrumented unit tests in 131 suites
- [x] 38.69% unit line coverage report regenerated
- [x] 3 warmup, 238 concurrent, and 143 serial integration tests
- [x] Live non-root `127.0.0.1:80:80` publication
- [ ] Docker Compose V2 parity (downstream Compose pin)

## Compatibility and risk

The alternate path is restricted to explicit loopback addresses below 1024.
An interface-scoped probe accepts `127.0.0.1` and rejects another loopback
destination; unassigned addresses fail before listener creation.

## Commit tracking

- `71cdae6b695508086cef81b94e9ad77a633635f6`
  (`fix(network): bind privileged loopback ports`)
