# Pull Request: select `bad_certificate` for Darwin internal verification failures

## Summary

- Add an internal optional BoringSSL failure-alert control to `CustomVerifyManager`.
- Use `SSL_AD_BAD_CERTIFICATE` only for Darwin's Security.framework system-default verifier.
- Preserve alert-unspecified behaviour for public custom verification callbacks.
- Add focused manager/bridge/Darwin coverage and retain the independent Docker CLI regression certificate.

See the companion [issue handoff](ISSUE-fluentd-tls-alert-control.md).

## Intended review delta

Apply signed commit `a9d648535c62e640d1df258a70c9117a8ddea43e` from the local branch `upstream/fluentd-tls-alert-control-01` only after rebasing it onto a fresh `apple/swift-nio-ssl:main` and reviewing overlap with current upstream TLS verification work. The local source baseline is the Container-vendored `d930168b86f46ca51a4bc09c5ca45c1833db8067` snapshot, so it is not presented as a current-stock rebase.

The change exposes BoringSSL's `SSL_AD_BAD_CERTIFICATE` through the existing shim, stores an optional failure alert in `CustomVerifyManager`, and propagates it through the `SSL_set_custom_verify` callback only when the internal verification future fails. The Darwin default manager supplies that optional alert. Public callback-backed managers keep `nil`, so an application callback's failure leaves the alert unspecified exactly as before.

## Validation

On this MBP:

```console
swift format lint --strict Tests/NIOSSLTests/CustomVerifyManagerTests.swift
swift test --enable-code-coverage --filter 'NIOSSLTests.CustomVerifyManagerTests|NIOSSLIntegrationTest/testMacOSConnectionFailsIfServerVerificationOptionalAndPeerPresentsUntrustedCert'
```

The focused suite passes seven tests. It covers internal failure, internal success, pending verification, both public callback forms, Darwin default-manager configuration, and the existing untrusted-peer integration path. Every new executable Swift line is covered; the C shim assertion confirms alert value `42`.

The downstream same-MBP Docker CLI certificate uses a self-signed Fluentd TLS receiver. Docker CLI `29.7.1` / Engine `29.2.1` and two exact-fingerprint Container candidates all observe `SSLV3_ALERT_BAD_CERTIFICATE`, the same rejected `created` lifecycle state and user-facing diagnostic, and exact candidate cleanup. The retained results are named in the companion contract handoff.

## Compatibility and risk

- No public NIOSSL API is added or changed.
- The alert changes only when Darwin's internal system-default verifier rejects a certificate.
- Public custom-verifier callbacks, pending verification, successful verification, explicit trust roots, and non-Darwin paths retain their existing semantics.
- This does not claim trusted TLS delivery, hostname/SNI changes, or a full TLS logging-provider matrix.
- The downstream candidate durations are retained for post-functional performance work; no performance claim is made by this source fix.

## Publication gate

- [x] Narrow signed local source/test candidate.
- [x] Focused strict-format, coverage, and integration validation.
- [x] Dependent Docker CLI reference and two exact-fingerprint candidate certificates.
- [x] Local issue/PR handoff record.
- [ ] Fresh stock-Apple rebase and overlap review.
- [ ] Stock focused and repository validation.
- [ ] Programme-wide publication gate and explicit authorization.
