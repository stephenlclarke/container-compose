# Isolate Compose Runtime Validation Across Shared macOS Services

## Problem

The full Docker Compose parity suite uses an isolated Container application root, but Container's API server and plugin helpers still occupy stable launchd/XPC labels in one namespace for the current macOS user. Another local workflow or self-hosted runner can therefore stop or replace the exact runtime during a long parity run even when both jobs use different app roots.

Two parity attempts on 30 July 2026 were invalidated when a devcontainer self-hosted workflow replaced the expected Container API server mid-run. One preflight correctly detected that the running API server had changed from expected commit `5119fea95e5c7820c4deceec75b59fadfa8f61c3` to `5973b9cc`; another lost its XPC connection during Compose Bridge. These were host-ownership collisions rather than failed Docker/container-compose assertions.

Long live operations also exposed two ambiguous transport outcomes:

- an idempotent image pull could report a typed XPC interruption even though one bounded replay was safe; and
- container deletion could report an interruption after the runtime had already removed the container, making a blind replay unnecessary and potentially misleading.

## Expected Behavior

- Serialize every cooperating long-running Compose workflow that can stop, start, or replace Container services under the same macOS user.
- Keep marker-protected application-root cleanup independent from the host service lock.
- Reuse a retained init-image archive from the exact Containerization revision instead of rebuilding it for every run.
- Treat runtime startup as ready only after a real API list round trip.
- Restart the exact matched runtime at most once after an XPC `Connection interrupted`/`Connection invalid` start or a failed API-readiness round trip.
- Retry an image pull exactly once only for a typed recursive `ContainerizationError.interrupted`.
- Never blindly retry container deletion; accept an interrupted delete only when direct discovery proves the target is absent.
- Preserve every parity fixture's original failure and timing without a fixture-level retry.
- Document that the advisory lock protects participants only and cannot isolate a non-cooperating repository or runner.

## Ownership Boundary

The lock, retained init archive, startup readiness gate, and bounded operation recovery are Compose validation/provider responsibilities. They change no Apple runtime source and do not claim to resolve the lower-runtime continuation/startup work tracked as `XPC-304`.

The stable per-user launchd/XPC namespace is a generic Container constraint. A unique app root isolates data, not service ownership. Every host workflow must use the same advisory lock or be explicitly quiesced for an authoritative run.

## Acceptance Criteria

- [x] `Tools/ci/container-runtime-lock.sh` acquires `/tmp/container-compose-runtime-${UID}.lock` with a bounded configurable wait and is reentrant inside one workflow.
- [x] The parity harness and Current VHS workflow acquire the same lock before operating the shared runtime.
- [x] A deterministic test proves a contender cannot acquire the lock until its holder releases it.
- [x] The harness can load `CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE` and configure the exact `vminit:container-compose` image without a source rebuild.
- [x] Startup requires `container list --all --format json` and performs at most one stop/start recovery.
- [x] Focused tests cover retained archive loading and one transient startup interruption.
- [x] Image-pull tests prove one typed interrupted retry and no broad error retry.
- [x] Deletion tests prove a typed recursive interruption is accepted only after confirmed absence and that discovery failure preserves the original error.
- [x] `make check` and the full unit gate pass 1,277 Swift tests in 46 suites plus all Go packages.
- [x] A 10-repetition bridge stress run and one controlled 62-target full parity run pass with retained timing/fingerprint evidence.
- [ ] Every other repository and self-hosted workflow using Container under the same user adopts the same lock; until then, authoritative windows must explicitly coordinate or quiesce non-participants.
- [ ] Exact-revision CodeQL evidence is recorded after the owner explicitly re-enables the manually disabled workflow.

## Controlled Evidence

The authoritative run used container-compose `4a2e0003496c9f96afcc0b3f3d54124ebc09b25b`, Container `5119fea95e5c7820c4deceec75b59fadfa8f61c3`, Containerization `971fc7e5e27467ebd6227e1ae54f3e5c23de87b4`, Docker Compose 5.3.1, and Docker Engine 29.2.1 on an arm64 Mac17,9 running macOS 26.5.2. The retained init archive has SHA-256 `51cd9ab90c4d12060701fa7ade5ebbc7f097870c1f5157a67de3d0124ac56d4d`.

All 62 maintained targets passed in 1,024.25s real time, 257.89s user time, and 327.29s system time, with a 4,239,622,144-byte maximum resident set size. The embedded bridge comparator measured Docker/candidate `up` medians of 0.151s/1.101s (7.30×) and `down` medians of 10.179s/5.969s (0.59×). A separate 10-repetition run measured 6.78× and 0.58× respectively.

Evidence remains under `.build/parity/full-4a2e0003-controlled/` and `.build/parity/host-namespace-interrupted-delete-fix-rerun-2/`. Two SwiftNIO event-loop shutdown warnings during image-volume builder teardown remain in the full log; every build and parity assertion completed, so they are retained as backend cleanup evidence.

## Commit Tracking

- `9a95ec8cc5a84e15a187ff20ccf948e9ac14bfe9` — `fix(ci): isolate container runtime validation`
- `4a2e0003496c9f96afcc0b3f3d54124ebc09b25b` — `fix(runtime): recover interrupted XPC operations`

## Compatibility and Deletion

The new lock and harness paths affect only validation/release workflows that opt in. Runtime-backed user commands preserve existing public syntax and errors. The pull retry is limited to an idempotent operation and one typed error class; deletion requires the intended postcondition rather than returning success from an ambiguous transport error.

Remove the Compose-side recovery only when the lower runtime provides an equivalent typed request/result contract that makes these bounded checks redundant. Do not remove the host-ownership documentation merely because app-root isolation improves; stable service labels must also become independently owned or namespaced.
