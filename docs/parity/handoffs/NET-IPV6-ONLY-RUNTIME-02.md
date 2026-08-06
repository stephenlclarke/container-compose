# NET-IPV6-ONLY-RUNTIME-02 Handoff

## State

`Verified`. The narrow Docker IPv6-only oracle and an exact source-matched
candidate both complete `up`, inspect, service-name `ping -6`, and `down` on
this MBP. The candidate proof also exposed and fixes the generic duplex build
stream completion cycle that had prevented the runtime certificate.

## User-visible contract

A Compose project declaring `enable_ipv4: false`, `enable_ipv6: true`, and
`fd00:2026:806::/64` must create, start, inspect, connect, and remove a
service network with no IPv4 endpoint and working service-name `ping -6`.

This is a deliberately narrow runtime contract. It does not certify custom
network or IPAM drivers, multiple pools, allocation ranges, auxiliary
addresses, namespace joins, or release-grade comparable performance.

## Docker oracle

The same-MBP Docker Compose `5.4.0` / Docker Engine `29.2.1` (API `1.53`)
reference and candidate are retained in the new marker-protected certificate
root `/private/tmp/container-compose-network-ipv6-only-a661e67.deQlGB`.
The reference creates the IPv6-only network, records no IPv4 endpoint and an
address in `fd00:2026:806::/64`, passes service-name `ping -6`, and confirms
project-network removal after `down`.

## Verified candidate runtime certificate

The source-matched candidate uses these exact inputs:

| Input | Exact identity |
| --- | --- |
| Compose | `19d9256c30475c67db8da33c080377c658290142`; debug binary SHA-256 `0fab111282c0871ac54b3511e80b6de0f350b3a2bbad1671e07e2f1946c2b9d6` |
| Container | `a661e67c8e7713483eb448493c7b4a35f346d9b3` |
| Containerization | `cfb00bbf3523079fe2ab9fb6b8e9b3504eff77e5`; source-built `vminit:container-compose` archive SHA-256 `0c16d06e8e7142205db8cc1dd820c863f0b7c5303295a4b4d6998cc163680873` |
| Engine API | `4949e743675f00ec102f7acacdb4e990409e383f` |
| Builder shim | `418e3c50f1ae664da3637ad81df8fc70ce630fd9`; `docker.io/library/container-builder-shim:completion-418e3c5`, archive SHA-256 `d8c65304a8248b8e736752ca52a3e75ee8fe1c6339dd9de3601935d7329926ab` |
| Runtime root | `/private/tmp/container-compose-ipv6-runtime-a661e67.2qZ7QI` (`.container-compose-runtime-root`) |

`FINGERPRINT-PREFLIGHT.json` and `FINGERPRINT-COMPLETE.json` agree exactly
(`preflight_sha256` `3b8b0b3abf0a66c2dd50eea894e01aeeb0ae58cb3467d46bf22266a2b3973b7c`).
The candidate network has `enableIPv4: false`, `enableIPv6: true`, an empty
IPv4 reservation list, subnet `fd00:2026:806::/64`, and only
`fd00:2026:806:0:f467:9eff:fe88:ceb/64` on the observed server attachment.
It passes `ping -6` by service name and its `down` record proves the network is
gone. The matched runtime stopped cleanly after the certificate.

Diagnostic durations are Docker `up`/connectivity/`down` = 0.366235 / 0.111466
/ 10.232049 seconds and candidate = 3.330545 / 0.990984 / 6.327614 seconds.
They are a debug runtime measurement, not a release-grade comparable-or-better
performance claim.

## Historical attempted-candidate inputs

The attempted candidate used the local matched source stack:

| Input | Exact identity |
| --- | --- |
| Compose | `cd7250046af6aa90b56ee2d5f5b2ba79269f30a5`; local tracked diff `04e7be0e25f9b840b382dcf1664f3a4d85db40aa4bf137fc7a7762101f6069a2` |
| Container | `68cd7a6d9d97d3d7cbfe65080799a4779b96a333`; local tracked diff `3f015c423d7e739c1a18baceaeb66ee4fbbc35d8723f63b7fd3ebc34ea92cded`; local binary SHA-256 `290b7fa9b9ebacd31c9147b40483368532dbb3e11dcfce15b34a79ab64e8b2fe` |
| Containerization | `5338e6685df56b8c15b49d0e7dd272a87abe0865`; local tracked diff `373e190e7387fae66aaed9447ecf57f6001a3a6281d987465fc35a1a02940e9e` |
| Builder image | `ghcr.io/stephenlclarke/container-builder-shim/builder@sha256:6cfb001d6fcf46283526df084351c20fd77e473eabaa9bf55e9327cc1d882f0c` |
| Runtime root | `/private/tmp/container-compose-ipv6-only-runtime.XI69kV` (`.container-compose-runtime-root`) |
| Candidate root | `/private/tmp/container-compose-network-ipv6-only-candidate.YqHoeU` (`.container-compose-network-ipv6-only-root`) |

The candidate script did not start, so it could not write its normal
source/dependency/binary/guest/root fingerprint. This table and the retained
bootstrap log are the preflight fingerprint; do not infer a candidate Compose
runtime result from them.

The tracked-diff hashes are historical inputs captured at attempted-candidate
time. The temporary local-package `Package.resolved` overlays used solely to
build those local paths were restored afterwards; no dependency pin change is
included in the checkpoint.

## What changed and what failed

The wrapper initially started a source-built guest-image path with
`--disable-kernel-install`. That was a real bootstrap bug: no default arm64
kernel had been materialised. It is corrected in
`scripts/run-with-container-runtime.sh` to use `--enable-kernel-install` for a
source-built init image; the exact source-built and prebuilt-init Python
regressions pass.

The first corrected attempt is retained at
`/private/tmp/container-compose-network-ipv6-only-candidate.EeSlUg`. It built
the guest image through BuildKit OCI export `#16 DONE` and was later terminated
before the native CLI's post-export image ingestion was observed to complete.

One attempted correction was rejected rather than treated as a product result:
the cached `containerization-dev:6.3.0` OCI archive at
`/private/tmp/container-compose-ipv6-only-builder.ZGZgGM/containerization-dev-6.3.0.oci.tar`
(SHA-256 `3d7a9cd4fa7f58571da23ac59e482ffc8ba3bedcb6b5d8774cc84dfbff4236e3`)
is a development image, not the required builder-shim image. Its runtime log
records the missing `/usr/local/bin/container-builder-shim` target.

The next attempt used the correct digest-pinned default builder and reached the
same OCI export (`#16 DONE 33.3s`). Its exact process sample is
`/private/tmp/container-compose-network-ipv6-only-candidate.YqHoeU/container-build-completion-hang.sample.txt`.
The sample was collected 106 seconds after BuildKit reports its session
finished, before the process group was terminated. Source inspection shows that
after BuildKit export `BuildCommand` calls `ClientImage.load`, `image.unpack`,
and image tagging. The active XPC callbacks through
`ProgressUpdateClient.createEndpoint` and
`ProgressUpdateClient.handleProgressUpdate` (including source lines 49, 89,
144, 159, and 160) are therefore consistent with expected host-side unpack
progress, not proof of a terminal XPC hang. The runtime was stopped by its
exact process group and marker-protected root cleanup; no candidate services
were started.

This corrects a failed assumption. `ProgressUpdateClient` must not be modified
from the sample alone.

## Verified lower completion boundary

The separately bounded, marker-protected source-init certificate is retained at
`/private/tmp/container-build-completion-exact-evidence.s0S09P` with isolated
runtime root `/private/tmp/container-build-completion-exact-runtime.fT0PRk`.
Its fingerprint records Container
`e1855ae21dcf829e0c514435398037b0f91cca8e`, Containerization
`2f9b44dbb7ce87270ee46f85a4327d7c1e1e57ab`, and rebuilt CLI, API server,
core-images, and runtime-plugin hashes from that same bundle. The log records
BuildKit `#16 DONE`, `vminit:container-compose` creation, runtime restart,
`system status` with the same API-server commit, and `runtime_exit_code=0`.

That historical lower-stack certificate did not by itself assert that the
IPv6-only Compose candidate had started or passed. The later exact certificate
above supplies that missing runtime proof.

## Completion-cycle correction

The fresh candidate found a genuine generic lower-stack defect rather than a
network failure. After successful BuildKit execution, the host kept its request
stream open while the shim waited for request EOF; the host in turn waited for
a terminal response. Container commit
`a661e67c8e7713483eb448493c7b4a35f346d9b3` treats a terminal
`CommandComplete` packet as `buildComplete` and finishes the request half.
Builder-shim commits `89778a9f1938331c9b7cb0094831358e2b730d71` and
`418e3c50f1ae664da3637ad81df8fc70ce630fd9` send one terminal completion packet,
wait for the request stream to finish, and leave ownership of the client status
channel with the client.

Stephen-owned [Container issue #82](https://github.com/stephenlclarke/container/issues/82)
records the exact correction and is closed. The generic source/test series has
local `unsubmitted` Apple-shaped issue and pull-request handoffs only; it has
not been published or submitted upstream.

## Focused proof

- The exact candidate certificate above passes after one fresh runtime start;
  the preflight and completion fingerprints match and both source worktrees
  were clean.
- Container `BuildPipelineCompletionTests` passes 2/2 at the exact
  `a661e67` source revision. Instrumented coverage executes both branches of
  `throwIfBuildComplete` (100% changed executable lines).
- Builder shim `go test ./pkg/stream ./pkg/server -count=1` and `go vet` pass.
  `Send` and `buildCompletePacket` are each 100% covered. `PerformBuild` is the
  real BuildKit boundary and remains 0% unit-instrumented; the exact CLI
  certificate is its behavioral proof rather than a fabricated mock.
- `shellcheck scripts/run-with-container-runtime.sh` and the nine focused
  `Tools/ci/test_run_with_container_runtime.py` tests pass.

- Historical Docker fixture: `/private/tmp/container-compose-network-ipv6-only-static.Pr3F2F`.
- Compose source model/resource tests: `ComposeRuntimeResourcesTests` (9
  passing tests), plus adapter dry-run and `up` preflight tests.
- Go normalizer: `go test ./...` in `Tools/compose-normalizer` passes.
- Container: `NetworkConfigurationTest` (21 passing tests).
- Containerization: `InterfaceTests` (8 passing tests) and
  `LinuxContainerTests.ipv6OnlyInterfaceOmitsIPv4GuestConfiguration` pass.
- Wrapper regression: the source-built and prebuilt-init cases in
  `Tools.ci.test_run_with_container_runtime` both pass.

The historical tests establish source behavior; the fresh certificate provides
the missing runtime result.

## Safe resumption

This contract is complete. Select a different discrete advanced-network/IPAM
contract next: custom driver/provider behaviour, range and auxiliary-address
semantics, multiple durable pools/reconciliation, or release-performance
evidence. Do not use this narrow IPv6-only proof to claim any of those gaps
closed.

Before any future upstream publication, recheck current Apple `main`, isolate
the generic source/test delta, and run the Apple handoff review gate. No Apple
issue, pull request, push, comment, hosted CI, or other external publication
occurred here.

The Slack START thread is `1786022430.804239`; send this contract's END reply
there after the local documentation checkpoint is clean.
