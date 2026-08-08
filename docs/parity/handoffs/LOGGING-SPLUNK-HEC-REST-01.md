# LOGGING-SPLUNK-HEC-REST-01 Handoff

## State

`Verified` — signed local Container `e188f9e8` maps the HTTP
`host.docker.internal` connection route to loopback while retaining the
Docker-visible HTTP authority. The exact focused XCTest, signed package, and a
fresh marker-protected isolated runtime candidate all passed. The candidate's
normalized public result agrees with the pinned Docker oracle; no performance
measurement is a completion gate for this contract.

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

- The Compose fixture was checked at pre-record checkpoint
  `e03ba18af6e104cbf236b68467b890676b38ca57`; its bytes are SHA-256
  `ae4ad90e7fdd74e6bf99867f7b3b684a546740ac1bd63722d074e3dc31fc569c`.
- Matched Container source is signed
  `e188f9e8` on `upstream/docker-wait-acknowledgement-01`.
- Existing detached compatible inputs are Containerization
  `38d9c695e7a6915e5ce45d12c893dc323a661af7` and Engine API
  `afb8a8f68ed56829b669c95cbddb488a68dc9175`.
- The signed Homebrew candidate archive is SHA-256
  `6674e402f308e1172bcd56b4c9aebc5a4302e8f83c02e437b679e543bdb6292b`.
  Its CLI, API server, engine, logging runtime plugin, and guest/init archive
  are listed in the retained candidate fingerprint.

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
4. The exact filtered XCTest passed at
   `/private/tmp/splunk-hec-package-e188-01.djPh1c/focused-xctest.log`:
   `SplunkURLSessionTransportLoopbackTests.productionHTTPTransportRoutesDockerHostAliasNatively`.
5. `make homebrew-package` produced the signed archive above from the same
   source/dependency graph. The extracted CLI, API server, engine, runtime
   plugin, core-image plugin, network plugin, machine API server, and semantic
   helper all passed `codesign --verify --strict`; their SHA-256 values are in
   `/private/tmp/splunk-hec-package-e188-01.djPh1c/candidate-fingerprint.txt`.
6. The fresh isolated candidate used app root
   `/tmp/checr-e188-01.lDidfM`, guest/init archive SHA-256
   `5d4201135affb9bb0ce34ebcb184551689a214d3118b75564a8fa498667d77f6`,
   and fixture root
   `/private/tmp/splunk-hec-package-e188-01.djPh1c/fixture`. It passed the
   bounded public Docker-socket fixture. Its normalized result matches Docker
   on driver, request count/path, authorization result, gzip setting, ordered
   events, tag shape, exit state/code, and cleanup. Retained raw request data
   remains mode `0600` inside a marker-protected root.

## Completion criteria

- The exact focused XCTest passed.
- The exact signed package passed one new marker-protected candidate agreement
  check for endpoint, authorization, decoded payload/order, exit state, inspect
  driver projection, and owned cleanup.
- The candidate exited cleanly inside its five-minute liveness boundary.
- The changed route has a direct focused regression. Coverage remains an
  improvement target, not a functional completion gate for this contract.
- The final documentation checkpoint records the evidence. Comparative
  performance is intentionally deferred.

## Blocker criteria

There is no active blocker. A future exact-fingerprint mismatch, hang, timeout,
cleanup failure, or public reference/candidate behavioral difference blocks a
successor immediately. Performance optimization and comparative timing are
deferred unless a liveness failure appears.

## Safe handoff

Retain the Docker oracle, first failing candidate, final candidate root
`/private/tmp/splunk-hec-package-e188-01.djPh1c`, signed source/fixture
checkpoints, and isolated runtime root `/tmp/checr-e188-01.lDidfM`. The final
runtime has stopped; its marker protects any later owned cleanup. Do not modify
the user-owned devcontainer runtime or publish externally. The verification
slice START thread is `1786221201.266729`.
