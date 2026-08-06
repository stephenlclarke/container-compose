# NET-IPV6-ONLY-RUNTIME-02 Handoff

## State

`Blocked`. The narrow Docker IPv6-only network oracle and source-level
projection work pass, but the exact candidate cannot reach `container compose
up`: the lower `container build` used to materialise the guest init image
finishes its OCI export and does not return to the caller.

## User-visible contract

A Compose project declaring `enable_ipv4: false`, `enable_ipv6: true`, and
`fd00:2026:806::/64` must create, start, inspect, connect, and remove a
service network with no IPv4 endpoint and working service-name `ping -6`.

This is a deliberately narrow runtime contract. It does not certify custom
network or IPAM drivers, multiple pools, allocation ranges, auxiliary
addresses, namespace joins, or release-grade comparable performance.

## Docker oracle

The same-MBP Docker Compose `5.4.0` / Docker Engine `29.2.1` (API `1.53`)
reference is retained at
`/private/tmp/container-compose-network-ipv6-only-static.Pr3F2F`. Its
marker-protected fixture creates the IPv6-only network, records an empty IPv4
endpoint field and an address in `fd00:2026:806::/64`, passes service-name
`ping -6`, and confirms project-network removal after `down`.

The final non-live harness rerun after the fingerprint/harness changes also
passes at `/private/tmp/container-compose-network-ipv6-only-static-verify.QEbGza`.

The fixture's source and binary record is in `fingerprint.json`: Compose source
`cd7250046af6aa90b56ee2d5f5b2ba79269f30a5`, local tracked-diff SHA-256
`04e7be0e25f9b840b382dcf1664f3a4d85db40aa4bf137fc7a7762101f6069a2`, and
debug Compose binary SHA-256
`ab1ba5a00a396bd4040168350ea36f5b446b77cc6994008c83693925f4fbccae`.

## Exact blocked candidate inputs

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
the guest image through OCI export `#16 DONE` and then did not return from the
`container build` client.

One attempted correction was rejected rather than treated as a product result:
the cached `containerization-dev:6.3.0` OCI archive at
`/private/tmp/container-compose-ipv6-only-builder.ZGZgGM/containerization-dev-6.3.0.oci.tar`
(SHA-256 `3d7a9cd4fa7f58571da23ac59e482ffc8ba3bedcb6b5d8774cc84dfbff4236e3`)
is a development image, not the required builder-shim image. Its runtime log
records the missing `/usr/local/bin/container-builder-shim` target.

The next attempt used the correct digest-pinned default builder, reached the
same final OCI export (`#16 DONE 33.3s`), and still did not return. Its exact
process sample is
`/private/tmp/container-compose-network-ipv6-only-candidate.YqHoeU/container-build-completion-hang.sample.txt`.
The main thread is waiting in `mach_msg`; active XPC callbacks resolve through
`ProgressUpdateClient.createEndpoint` and
`ProgressUpdateClient.handleProgressUpdate` (including source lines 49, 89,
144, 159, and 160). The runtime was stopped by its exact process group and
marker-protected root cleanup; no candidate services were started.

This is the second evidence-based lower-runtime result after the bootstrap
correction. Per the delivery workflow, do not rebuild or restart the guest
image again under this contract.

## Focused proof retained

- Docker fixture: `/private/tmp/container-compose-network-ipv6-only-static.Pr3F2F`.
- Compose source model/resource tests: `ComposeRuntimeResourcesTests` (9
  passing tests), plus adapter dry-run and `up` preflight tests.
- Go normalizer: `go test ./...` in `Tools/compose-normalizer` passes.
- Container: `NetworkConfigurationTest` (21 passing tests).
- Containerization: `InterfaceTests` (8 passing tests) and
  `LinuxContainerTests.ipv6OnlyInterfaceOmitsIPv4GuestConfiguration` pass.
- Wrapper regression: the source-built and prebuilt-init cases in
  `Tools.ci.test_run_with_container_runtime` both pass.

Those tests establish changed source behavior; they do not transform the
unreached runtime contract into `Verified`.

## Safe resumption

Select a separate lower vertical contract first:
`CONTAINER-BUILD-PROGRESS-COMPLETION-01`. Its Docker-equivalent user-visible
behavior is that a successful `container build` image export returns to its CLI
caller and closes progress/XPC lifecycle cleanly. Its focused proof must use an
isolated marker-protected root, the exact pinned builder image, a bounded build
that observes both `#16 DONE` and command exit, plus targeted regression tests
for the progress-client terminal lifecycle.

Only after that contract is independently `Verified` may this contract run one
fresh exact-fingerprint candidate certificate. Do not reuse a prior runtime
root, use the rejected development image archive as the builder, or claim an
IPv6-only candidate result before the harness writes `FINGERPRINT-PREFLIGHT.json`
and `FINGERPRINT-COMPLETE.json`.

Apple applicability is not yet established: the failure is in the local
Container source stack and has not been compared to Apple upstream source or
reproduced on an Apple revision. Preserve this handoff for any later
Apple-shaped issue/PR work; do not submit or publish anything from it. The
Stephen-owned tracker is [Container issue #80](https://github.com/stephenlclarke/container/issues/80);
comment with the terminal-progress/CLI-exit evidence and close it only when
the lower contract is fixed and verified.

The Slack START thread is `1786014513.346509`; send this contract's END reply
there. No push, hosted CI, Apple/upstream publication, or external PR is part
of this blocked handoff.
