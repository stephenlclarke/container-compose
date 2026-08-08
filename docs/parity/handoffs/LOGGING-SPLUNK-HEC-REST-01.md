# LOGGING-SPLUNK-HEC-REST-01 Handoff

## State

`Blocked` — the Docker oracle and a first exact-fingerprint candidate
identified a macOS native-host routing mismatch. Signed local Container
`e188f9e8` maps the HTTP `host.docker.internal` connection route to loopback
while retaining the Docker-visible HTTP authority. The production provider and
its focused test target compile, and a direct local HEC probe reaches loopback
while preserving that authority. The package-wide XCTest runner and a rebuilt
runtime candidate cannot currently be linked safely with the available local
disk headroom, so this is not `Verified`.

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
4. Exact `swift build --target ContainerLoggingProviders` passed in 97.66
   seconds at `/private/tmp/splunk-hec-provider-build-01.D5QBmx`; exact
   `swift build --target ContainerLoggingProvidersTests` passed in 93.04
   seconds at
   `/private/tmp/splunk-hec-provider-test-target-01.KSX09Q`. The latter
   compiles the direct regression but does not execute XCTest.
5. A focused `swift test --filter SplunkURLSessionTransportLoopbackTests` build
   was started with the exact detached graph but consumed free disk from about
   3.7 GiB to about 299 MiB before usable test output. Once the slice-owned
   build had exited, `swift package clean` recovered about 3.4 GiB. A later
   guarded retry reached the package-wide test link, where `ld` failed with
   `errno=28 (No space left on device)` after free space fell to 181 MiB. This
   is no passing-XCTest evidence.
6. The marker-protected temporary-probe root
   `/private/tmp/splunk-hec-alias-probe-01.lXf3au` builds the unmodified
   `e188f9e8` provider plus a retained test-only executable patch. Its
   redacted result records one `POST /services/collector/event/1.0`, a
   preserved `Host: host.docker.internal:<port>` header, matching Splunk
   authorization scheme/token, matching JSON body, and status `200`. The
   temporary detached worktree has been removed and the active source worktree
   is clean; this proves the corrected production route directly but is not a
   packaged candidate certificate.

## Completion criteria

- Restore enough local disk headroom for the package-wide XCTest link, then
  pass `SplunkURLSessionTransportLoopbackTests`.
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
reference/candidate behavioral difference is blocking. Current blocking
evidence is package-wide test linking with `errno=28`; the available 3.5 GiB
headroom is insufficient. The probe's completed duration is not a performance
gate. After two evidence-based corrections without a behavior or blocker-
evidence delta, preserve the root and hand off instead of retrying.

## Safe handoff

Retain the Docker root, first candidate root, signed source/fixture
checkpoints, and the three focused-build/probe roots above. Do not modify the
user-owned devcontainer runtime. Before a retry, confirm enough free disk for
the package-wide test link and package rebuild, use new evidence and runtime
roots, and prove one exact source/dependency/binary/guest/test fingerprint.
The current slice START thread is `1786219786.154999`.
