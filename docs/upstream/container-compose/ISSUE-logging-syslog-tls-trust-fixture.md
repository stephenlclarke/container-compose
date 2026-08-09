# Issue: Syslog TLS trust rejection lacks a reusable public-socket certificate

## Problem

The Syslog TLS trust-rejection contract has a retained Docker observation and a narrow Container correction, but no repository-owned fixture could certify the same behavior through Docker's CLI and a Container public socket. Repeating the previous ad hoc probe would leave the exact start phase, `created` state, requested LogConfig, TLS alert, authority visibility, and cleanup observations unprotected against future regressions.

## Resolution

Add `Tools/parity/check-docker-rest-syslog-tls-trust-failure.sh`. It uses a bounded self-signed receiver and unmodified Docker CLI calls, supports a strict pinned-reference lane and an optional native Container CLI authority check, emits machine-readable evidence, and removes its generated private key and exact failed container.

## Status

The Docker reference passes. The dependent Container candidate remains blocked until the MBP has enough free capacity to rebuild the exact source/dependency graph and capture two independent public-socket samples.
