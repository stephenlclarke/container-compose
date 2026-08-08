# LOGGING-SPLUNK-HEC-REST-01 Handoff

## State

`Implemented` — the Docker oracle and a first exact-fingerprint candidate
identified a macOS native-host routing mismatch. Signed local Container
`e188f9e8` maps the HTTP `host.docker.internal` connection route to loopback
while retaining the Docker-visible HTTP authority. The new focused regression
has not executed because its Swift build exhausted safe disk headroom, so this
is not `Verified`.

## User-visible contract

With a valid `splunk-url` and `splunk-token`, an unmodified Docker CLI must run
a cache-disabled `splunk` logging container and send its ordered stdout and
stderr records to a local Splunk HEC-compatible HTTP receiver. The contract will
use only the Docker behavior measured in this slice for endpoint path,
authorization header, payload shape, record order, process exit, inspect
projection, and owned cleanup. Receiver data and routine diagnostics must not
disclose the supplied token outside the expected Authorization header capture.

## Pinned Docker oracle

Same-MBP Colima with Docker CLI `29.7.1`, Engine `29.2.1`, API `1.53`, and
`alpine:3.20`. The marker-protected receiver root
`/private/tmp/docker-splunk-hec-contract-reference.8yzTk1` passed:

- one POST to `/services/collector/event/1.0`;
- `Authorization: Splunk <fixture token>` and no content encoding when gzip is
  disabled;
- one concatenated JSON request containing the `stderr-two`/`stderr` and
  `stdout-one`/`stdout` events, with the 12-character container-ID tag;
- `splunk` inspect projection, exited state, exit code `0`, and owned cleanup.

The protected result intentionally stores only a redacted authorization summary;
the raw request file is mode `0600` within the mode `0700` root.

## Affected repositories and pins

- `container-compose` local `main` fixture is signed
  `39f1ad761be416cd2d932f104e20d45af92a566a`.
- Matched Container source is signed
  `e188f9e8` on `upstream/docker-wait-acknowledgement-01`.
- Existing detached compatible inputs are Containerization
  `38d9c695e7a6915e5ce45d12c893dc323a661af7` and Engine API
  `afb8a8f68ed56829b669c95cbddb488a68dc9175`.

No remote, dependency pin, issue, PR, or upstream change is authorized.

## Focused proof

1. Docker reference fixture
   `Tools/parity/check-docker-rest-splunk-hec-contract.sh` passed `bash -n`,
   ShellCheck, and `--reference --strict`.
2. First exact-fingerprint candidate
   `/private/tmp/ctr-splunk-hec-final.BUj0a5` reached a successful workload
   exit but captured no HEC request. It exited `1` only because the fixture
   correctly rejected that mismatch; it did not hang or time out.
3. Signed correction `e188f9e8` adds
   `productionHTTPTransportRoutesDockerHostAliasNatively`, which asserts that a
   local loopback receiver is reached through the Docker host alias while the
   HTTP `Host` authority remains `host.docker.internal:<port>`.
4. A focused `swift test --filter SplunkURLSessionTransportLoopbackTests` build
   was started with the exact detached graph but consumed free disk from about
   3.7 GiB to about 299 MiB before usable test output. Once the slice-owned
   build had exited, `swift package clean` recovered about 3.4 GiB. This is no
   passing-test evidence.

## Completion criteria

- Rebuild the signed source only when disk headroom safely permits it, then pass
  `SplunkURLSessionTransportLoopbackTests`.
- Package that exact binary and rerun one new marker-protected candidate so it
  agrees with Docker on endpoint, authorization, decoded payload/order, exit
  state, inspect driver projection, and owned cleanup.
- The candidate exits cleanly and never hangs or exceeds a bounded liveness
  timeout.
- Any changed code has direct focused tests; coverage should approach 90% when
  disk headroom permits instrumentation.
- A clean signed local checkpoint records the evidence. Comparative performance
  is intentionally deferred.

## Blocker criteria

An exact-fingerprint mismatch, hang, timeout, cleanup failure, or a measured
reference/candidate behavioral difference is blocking. Disk headroom below that
required for the focused rebuild is an environmental blocker. After two
evidence-based corrections without a behavior or blocker-evidence delta,
preserve the root and hand off instead of retrying.

## Safe handoff

Retain the Docker root, first candidate root, and signed source/fixture
checkpoints above. Do not modify the user-owned devcontainer runtime. Before a
retry, confirm enough free disk for the source build and use a new evidence and
runtime root. The active slice START thread is `1786218665.126109`.
