# Issue: Syslog TLS trust rejection lacks a reusable public-socket certificate

## Problem

The Syslog TLS trust-rejection contract has a retained Docker observation and a narrow Container correction, but no repository-owned fixture could certify the same behavior through Docker's CLI and a Container public socket. Repeating the previous ad hoc probe would leave the exact start phase, `created` state, requested LogConfig, TLS alert, authority visibility, and cleanup observations unprotected against future regressions.

## Resolution

Add `Tools/parity/check-docker-rest-syslog-tls-trust-failure.sh`. It uses a bounded self-signed receiver and unmodified Docker CLI calls, supports a strict pinned-reference lane and an optional native Container CLI authority check, emits machine-readable evidence, and removes its generated private key and exact failed container.

## Status

Closed on 2026-08-09. The Docker reference passes, and the rebuilt Container
candidate at `c7924e375d98d82af37902f4a0c310ee389eab97` passed two
independent public-socket samples. Both retained the requested Syslog
`tcp+tls` LogConfig, rejected start with an unknown-authority diagnostic,
observed `bad_certificate` at the receiver, preserved the public `created`
state, and removed the failed container and generated private key. Evidence is
retained under
`/Volumes/SSD/github/evidence/container-family-stable-01/public-contracts/syslog-tls-sample-{1,2}/`.
