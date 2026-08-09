# Issue: allow Darwin's internal verifier to select the TLS failure alert

## Steps to reproduce

On macOS, configure an NIOSSL client with the internal Security.framework trust verifier and connect it to a server with an untrusted self-signed certificate. The verifier correctly rejects the peer, but the `SSL_set_custom_verify` callback leaves BoringSSL's `outAlert` unchanged. BoringSSL therefore sends `certificate_unknown` rather than the `bad_certificate` alert selected by the macOS/Docker trust-failure oracle.

The same issue is observable through a cache-disabled Fluentd TLS logging startup: Docker Engine `29.2.1` rejects the self-signed peer and the bounded server records `SSLV3_ALERT_BAD_CERTIFICATE`; the pre-fix Container graph produced `SSLV3_ALERT_CERTIFICATE_UNKNOWN` despite returning the same user-facing trust diagnostic and retained `created` state.

## Problem description

NIOSSL needs an internal-only way for its Darwin system-default verifier to request the BoringSSL failure alert that represents a failed certificate verification. The public `NIOSSLCustomVerificationCallback` and metadata callback must remain unchanged: application callbacks currently do not select an alert, so assigning an alert to every custom verifier would be an observable API behaviour change.

The implementation should:

1. Expose BoringSSL's `SSL_AD_BAD_CERTIFICATE` through the existing C shim rather than duplicating its wire value in Swift production code.
2. Carry an optional failure alert through `CustomVerifyManager` and write it through BoringSSL's `outAlert` only when an internal verification promise resolves as failed.
3. Configure the optional alert only for the Darwin Security.framework system-default verifier.
4. Preserve public custom-verifier success, failure, retry/pending, hostname/trust-root, and non-Darwin behaviour.
5. Add focused manager/bridge and Darwin configuration regression coverage.

## Local candidate and validation

The local Apple-shaped candidate is signed commit `a9d648535c62e640d1df258a70c9117a8ddea43e` on `upstream/fluentd-tls-alert-control-01`, based on the vendored `d930168b86f46ca51a4bc09c5ca45c1833db8067` source snapshot. It adds the optional internal alert path, leaves public callbacks alert-unspecified, and adds six manager/bridge/Darwin regressions plus the existing macOS untrusted-peer integration case. Strict formatting and the focused seven-case suite pass with every new executable Swift line hit; the C shim confirms alert value `42`.

The dependent same-MBP Docker CLI certificate is retained at [LOGGING-FLUENTD-TLS-TRUST-FAILURE-REST-01](../../parity/handoffs/LOGGING-FLUENTD-TLS-TRUST-FAILURE-REST-01.md). Its Docker reference observes `SSLV3_ALERT_BAD_CERTIFICATE` in `0.314402875s`; two fresh exact-fingerprint Container release candidates using this NIOSSL patch observe the same alert, diagnostic, rejected state, and cleanup in `2.637404042s` and `1.223912417s`. Those durations are functional-run evidence only, not a performance claim.

## Tracking

- Local Container tracker: [stephenlclarke/container#87](https://github.com/stephenlclarke/container/issues/87), to be evidence-commented and closed after its clean local checkpoint.
- Compose contract handoff: [LOGGING-FLUENTD-TLS-TRUST-FAILURE-REST-01](../../parity/handoffs/LOGGING-FLUENTD-TLS-TRUST-FAILURE-REST-01.md).
- No Apple issue or pull request has been created. This is an `active-draft` local handoff; it requires a fresh rebase and overlap review against current `apple/swift-nio-ssl:main`, stock focused/repository validation, the programme-wide publication gate, and explicit authorization before any upstream action.
