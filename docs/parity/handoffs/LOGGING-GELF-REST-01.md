# LOGGING-GELF-REST-01 Handoff

## State

`Verified` as a narrow Docker CLI/public-socket GELF UDP contract. It does not claim all remote logging-driver, external-client, or release-performance parity.

## User-visible contract

The same unmodified Docker CLI creates a cache-disabled `gelf` container against Docker Engine 29.2.1 and against a fresh local Container public socket. The certificate proves default-gzip UDP delivery; ordered stdout, stderr, and binary payload records; priorities; selected environment/label metadata; tag expansion; unqualified image display; exited inspect state with blank public `LogPath`; unsupported remote history; native-authority visibility; and cleanup.

## Exact proof

The marker-protected root `/private/tmp/container-gelf-rest-v4.AR1wW6` contains `FINGERPRINT-PREFLIGHT.json`, archive/binary/guest hashes, Docker reference evidence, and three candidate result files. It records Container `9999d994ed45e06ed2c3144bb175230427116fbc`, local Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7`, local Engine API `4949e743675f00ec102f7acacdb4e990409e383f`, transitive Containerization `77f06d4c44341e04241941072fb69e2b85a6f5c1`, Compose `b790d76273062f66508f9de9807b0d9a182707d4`, Docker CLI 29.7.1, and Docker Engine 29.2.1.

The Docker reference passed in `0.680846750s`. Candidate public-socket runs passed in `1.567608333s`, `1.526945791s`, and `1.461681958s`. These are functional passes under the 10× regression guard, not a comparable-or-better performance claim.

The source-level regression is `AuthorityRemoteLogDriverPlaneTests.gelfProductionPlaneForwardsForegroundAndProviderBytes`; it passes three successive focused runs at the signed Container checkpoint. The correction replaces independently scheduled `FileHandle` pipe readers with one readiness-ordered poller and bounded POSIX reads, preventing an earlier stderr write from being deferred behind a later stdout write.

## Remaining boundary

GELF TCP reconnect/failure behavior, provider-wide failure/migration/security/pressure behavior, other remote-driver public-client lanes, Testcontainers/devcontainer adoption, release publication, and the full release performance matrix remain queued. The narrow TCP public-socket lifecycle is separately verified in [LOGGING-GELF-TCP-REST-01](LOGGING-GELF-TCP-REST-01.md). The candidate create route still returns a generated name instead of Docker's immutable 64-hex ID; [Container issue 74](https://github.com/stephenlclarke/container/issues/74) tracks that separately.

## Safe resumption

Keep the evidence root and signed Container checkpoint. Do not rerun broad gates for this completed narrow contract. Select a distinct queued contract, and poll Slack before any new slice START; the completed slice's START thread is `1785980213.576879`.
