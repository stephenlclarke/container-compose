# Pull Request: add the Syslog TLS trust-rejection parity fixture

## Summary

- Add a strict Docker REST fixture for cache-disabled Syslog `tcp+tls` trust rejection.
- Retain machine-readable Docker reference evidence and the active-contract handoff.
- Leave the contract blocked until an exact rebuilt Container candidate completes both required samples.

## Motivation and context

Docker accepts the requested Syslog LogConfig during create, then rejects start with a certificate-verification diagnostic. The receiver must observe `bad_certificate`, the public state must remain `created`, and cleanup must remove both the failed container and generated private key. This fixture makes that behavior reusable without treating a Docker-only result as Container support.

## Testing

- [x] `bash -n Tools/parity/check-docker-rest-syslog-tls-trust-failure.sh`
- [x] `shellcheck Tools/parity/check-docker-rest-syslog-tls-trust-failure.sh`
- [x] `markdownlint docs/parity/handoffs/LOGGING-SYSLOG-TLS-TRUST-REJECTION-06.md`
- [x] Strict Docker CLI `29.7.1` / Engine `29.2.1` reference run passes at `/private/tmp/container-rest-syslog-tls.reference.ZiBk37/result.json`.

## Compatibility and remaining risk

The fixture creates only a marker-protected temporary root and does not alter Docker, host trust stores, dependency pins, or the user Container runtime. It is an acceptance harness, not a claim that the current Container artifact has matched Docker; rebuilding the signed Container correction and capturing two candidate samples remain required.
