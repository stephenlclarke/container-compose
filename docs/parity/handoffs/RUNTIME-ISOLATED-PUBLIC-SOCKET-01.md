# RUNTIME-ISOLATED-PUBLIC-SOCKET-01 Handoff

## State

`Verified` — a marker-protected candidate Container runtime started and stopped through a unique launchd/Mach namespace and public Docker socket without replacing or stopping the user-owned `devcontainer-engine`. This is a runtime-isolation prerequisite, not a Docker logging or comparable-performance certificate.

## User-visible contract

A candidate Container public Docker socket must use a service namespace that is distinct from the user's default Container installation. The candidate may start, answer an unmodified Docker CLI `docker version`, and stop only services in its own namespace. The user-owned `devcontainer-engine` must remain responsive before and after that lifecycle.

## Explicit non-goals

This contract does not certify a logging driver, Compose project, Docker REST route beyond `docker version`, release artefact performance, generic coexistence for unmodified default-namespace callers, or the full shared-namespace and privileged-isolation programme gap. The debug, source-built guest timing is retained as diagnostic lifecycle evidence only.

## Pinned oracle and inputs

The public-client oracle is Docker CLI `29.7.1` / Docker Engine `29.2.1` / API `1.53` on this MBP. The candidate used:

- `container-compose` `main` at `40d109db071cd98f2b37300e417e478f00213b3c`;
- `container` `upstream/runtime-isolated-public-socket-01` at `c740a8f6a79ce176d03a941f49cdfe7350625a71`;
- Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7`; and
- Engine API `4949e743675f00ec102f7acacdb4e990409e383f`.

The candidate namespace was `io.github.stephenlclarke.container-compose.runtime.a46377784f5464874269b3ca`; its selected socket was `/tmp/container-engine-501-8806c2d9ecceef7b17c5576b/docker.sock`. The user baseline socket was `/var/folders/y1/z__p0wn53pl5l52x_b7vqp_40000gn/T/devcontainer/docker.sock`, which returned `29.7.1|1.1.0|linux` before and after the candidate.

## Implementation and focused proof

Container commit `c740a8f6a79ce176d03a941f49cdfe7350625a71` introduces `ContainerServiceNamespace`: the default remains stock-compatible, while a validated `CONTAINER_SERVICE_NAMESPACE` derives the API, Machine API, images, runtime, network, Engine launchd/Mach identifiers, and non-default Engine socket. System start, status, and stop remain bound to the selected namespace, and clients/plugins route through that same namespace. The focused Swift command ran 19 tests across `ContainerServiceNamespaceTests`, `SystemStartTests`, and `SystemStopValidationTests`; `ContainerServiceNamespace.swift` recorded 100% line, function, and region coverage. `bash -n`, ShellCheck, and `Tests/ScriptTests/TestInstallInit.sh` also passed.

Compose commit `40d109db071cd98f2b37300e417e478f00213b3c` derives an allowed namespace from the candidate root and UID, rejects an unsafe legacy global stop helper before mutation, verifies the namespace-derived `engineSocket` before start, stages the exact clean Containerization source with separate build scratch, and invokes only namespace-scoped start/status/stop. Its focused `Tools/ci/test_run_with_container_runtime.py` suite passed 14 tests with 99% branch coverage (`336` statements, `3` missed); Bash syntax, ShellCheck, Python compilation, and diff checks passed.

## Exact candidate certificate

The marker-protected candidate root `/private/tmp/ctr-isopub4.Id3j22` began empty and carries `.container-compose-runtime-root` with `container-compose isolated runtime state v1`. Preflight is retained at `/private/tmp/ctr-isopub4.Id3j22.preflight.txt`; the runner log is `/private/tmp/ctr-isopub4.Id3j22.run.log`.

- The staged package was `/private/tmp/container-runtime-isolated-public-socket-01/bin/debug/container-installer-unsigned.pkg` (`00f826e4e4f721119b7214e85cce6b087a8081a6dc64974b96c30455e2f68086`).
- The staged `container`, `container-apiserver`, and `container-engine` SHA-256 values were respectively `58d06b7d12111ba6702534793753774eec2252632dad1d757cc8eb8498b824eb`, `092a640d0babb2613f2737277ec67e213aaa9d0a8d0fc32035e249ae688fd2fb`, and `1bbb95dc4d70ea2148bc4d74294a0b82d205d421314c785a293868e66c259b79`.
- The staged source at `source-inputs/containerization` resolves exactly to `38d9c695e7a6915e5ce45d12c893dc323a661af7`. Its generated guest inputs are `init.rootfs.tar.gz` (`04d6d627e4df8a60e2b26295c97d166eccf798d340f0c4c37e4808615c114d3c`) and `initfs.ext4` (`bd04e6847a44bd883975ddbe5c393aff23bcde98ef2f495625ed707436a91f16`).
- The candidate ran `system start`, built the source-pinned guest, restarted with that installed image, returned `29.7.1|29.2.1|linux` through the unique public socket, then performed its trap-owned `system stop` and exited `0` after `722` seconds. This debug/source-build time is not compared with Docker.

Postflight proved the candidate socket absent, its Engine/APIServer/Machine/Core Images/network/runtime launchd labels all absent, and `system status --format json` reporting the expected socket with `engineStatus` and `status` both `unregistered`. The original four source repositories remained clean. The user `homebrew.mxcl.devcontainer` launchd service remained `running` and its public socket continued to answer the baseline version query.

## Completion criteria

All runtime-isolation completion criteria are met: the exact namespace/socket was selected before start, the public Docker client used it successfully, candidate-only stop removed its services and socket, the test root is marker-protected, source/dependency/binary/guest fingerprints are retained, and the pre-existing user runtime remained healthy.

## Next safe action

`LOGGING-FLUENTD-TCP-ACK-REST-01` is now `Verified` as a narrow consumer of this prerequisite: two new marker-protected namespace-aware roots passed its Docker TCP/ACK fixture and left the user runtime healthy. Their `6.525×` and `5.527×` timings are functional-only evidence, not a comparable-or-better performance result. The next logging contract must still use a new marker-protected root and its own Docker oracle; do not reuse this debug source-build run as logging or performance evidence.
