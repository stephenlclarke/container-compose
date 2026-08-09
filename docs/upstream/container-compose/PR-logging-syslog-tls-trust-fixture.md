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

The fixture creates only a marker-protected temporary root and does not alter Docker, host trust stores, dependency pins, or the user Container runtime. It is an acceptance harness; the subsequent Container result is recorded separately below so the Docker reference alone is never mistaken for Container support.

## Completion evidence

The rebuilt Container candidate at
`c7924e375d98d82af37902f4a0c310ee389eab97` subsequently passed two
independent public-socket samples on 2026-08-09. Both samples retained the
requested LogConfig, rejected start with the expected unknown-authority
diagnostic and `bad_certificate` receiver alert, preserved `created` state,
and completed exact cleanup. Evidence is retained under
`/Volumes/SSD/github/evidence/container-family-stable-01/public-contracts/syslog-tls-sample-{1,2}/`.
