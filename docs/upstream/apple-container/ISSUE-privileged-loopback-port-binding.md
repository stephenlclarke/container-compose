# Privileged loopback host ports fail for non-root users

## Upstream issue

Implements [apple/container#1985](https://github.com/apple/container/issues/1985).

## Reproduction

As a non-root user on macOS, publish a low host port to an explicit loopback
address:

```console
container run --rm --name low-port -p 127.0.0.1:80:80 alpine:3.20 \
  sh -c 'while true; do nc -l -p 80 -e echo ok; done'
```

Before the fix, `127.0.0.1:80` fails with `EACCES`, while `0.0.0.0:80`
succeeds. macOS permits the unprivileged wildcard bind; applying `IP_BOUND_IF`
or `IPV6_BOUND_IF` scopes that socket to the owning loopback interface.

## Required behavior

- Permit explicit IPv4 and IPv6 loopback publications below 1024 without root.
- Keep them inaccessible through other host interfaces.
- Preserve existing high-port, wildcard, and non-loopback behavior.
- Reject a requested loopback address that is not assigned to an interface.
- Support both TCP and UDP forwarders.

## Validation

- Seven address-resolution tests and four real TCP/UDP forwarder tests passed.
- `make coverage-unit` passed 1,131 tests in 131 suites and regenerated the
  unit report at 38.69% line coverage.
- The source-build integration gate passed 3 warmup, 238 concurrent, and 143
  serial tests.
- The live case successfully published `127.0.0.1:80:80` as the non-root MBP
  user, then inspected, stopped, and removed the container.

## Commit tracking

- `71cdae6b695508086cef81b94e9ad77a633635f6`
  (`fix(network): bind privileged loopback ports`)
