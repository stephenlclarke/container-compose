<!-- markdownlint-disable MD013 -->

# CONTAINER-BUILD-PROGRESS-COMPLETION-01 Handoff

## State

`Verified` as a narrow native Container completion-boundary certificate. It
unblocks the queued IPv6-only Compose runtime certificate, but it does not
certify advanced networking, Compose runtime behavior, or release performance.

## User-visible contract

After a successful BuildKit OCI export, native `container build` must finish
its own host-side image load, unpack, and tagging work, then return a process
result to the CLI caller. BuildKit's `#16 DONE` line alone is not a terminal
Container CLI event.

## Oracle and exact proof

The same-MBP Docker CLI/Buildx oracle against Docker Engine `29.2.1` / API
`1.53` returns after a marker-protected minimal OCI export. The exact native
candidate uses Container `e1855ae21dcf829e0c514435398037b0f91cca8e`,
Containerization `2f9b44dbb7ce87270ee46f85a4327d7c1e1e57ab`, Compose
`0fc88e86502fb5e669cc119bc5a787c12d795855`, and builder
`ghcr.io/stephenlclarke/container-builder-shim/builder@sha256:6cfb001d6fcf46283526df084351c20fd77e473eabaa9bf55e9327cc1d882f0c`.

Its marker-protected evidence root is
`/private/tmp/container-build-completion-exact-evidence.s0S09P`; its isolated
runtime root is `/private/tmp/container-build-completion-exact-runtime.fT0PRk`.
The fingerprint records the clean source revisions plus hashes for the rebuilt
CLI, API server, core-images plug-in, and runtime plug-in. The runtime log
records all of the following in order:

- BuildKit `#16 DONE`.
- Host-side image ingestion followed by a fresh source build of
  `vminit:container-compose`.
- Matched runtime restart and `system status` with API-server commit `e1855ae`.
- `runtime_exit_code=0`.

No executable source changed, because the exact candidate disproved the
suspected defect. The 90% changed-code coverage requirement therefore did not
apply; no low-value lifecycle change was introduced simply to create coverage.

## Correction retained as evidence

The earlier process group was stopped 106 seconds after the BuildKit export
boundary. Source inspection showed that `BuildCommand` then performs
`ClientImage.load`, `image.unpack`, and tagging. Its active progress/XPC
callbacks therefore did not establish a terminal XPC defect.

Stephen-owned [Container issue #80](https://github.com/stephenlclarke/container/issues/80)
contains the correction and exact acceptance evidence. It is closed as
`not_planned` because the reported defect was invalid evidence, not because a
known product gap was deferred. No Apple/upstream applicability is asserted.

## Safe resumption

Keep the exact evidence roots and this Compose checkpoint. Select the queued
`NET-IPV6-ONLY-RUNTIME-02` contract only after the silent Slack instruction
poll, rebuild a single exact matched stack, and run one fresh marker-protected
Compose candidate through create, start, inspect, IPv6 connectivity, and
cleanup. Do not reuse the historical post-export runtime root or infer a
network result from this lower-stack certificate.

The START thread is `1786019659.144949`; send the END reply there. No push,
hosted CI, Apple/upstream publication, or external PR is part of this verified
handoff.

<!-- markdownlint-enable MD013 -->
