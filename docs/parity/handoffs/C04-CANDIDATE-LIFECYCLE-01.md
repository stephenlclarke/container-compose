# C04-CANDIDATE-LIFECYCLE-01 Handoff

## State

`Blocked`. The Docker reference is valid, but the intended Dev Containers
candidate cannot build from one immutable dependency graph. No
`container-compose` C04 runtime result or performance result was produced.

## User-visible contract

Against the now-valid Docker C04 oracle, the Container Compose provider must
run the Dev Containers Compose lifecycle fixture and observe the selected
primary service and label, forced recreation, `term` termination, restart,
shutdown, and cleanup.

This handoff does not change the separately verified Docker-reference runner
contract in [LOGGING-PERF-C04-MOUNT-ROOT-01](../slice-ledger.md#logging-perf-c04-mount-root-01).

## Pinned reference

The Docker reference passed on this MBP in 4.337 seconds using
`@devcontainers/cli@0.88.0` at
`f683c29f64a20109b4453e5149807e390ff65133`, Docker Engine `29.2.1` (API
`1.53`), and the Docker Compose `5.3.1` wrapper with SHA-256
`90b2705314905295de430e2e021f490666c959accba18e0a784b32aecc04a034`.

## Candidate inputs and blocker evidence

The candidate root is
`/private/tmp/container-compose-c04-candidate.BjULUC`, protected by
`.container-compose-c04-candidate-root`. Its disposable detached Dev
Containers worktree begins at signed `3bd1e6230f7bbd19cc8491d233aa305cb7cecc31`.
Compose is signed `701143c44df2c56bf6d8e610d4a7cb04dac30ffc`; its executable
is unchanged from source `19d9256c30475c67db8da33c080377c658290142` and has
SHA-256 `0fab111282c0871ac54b3511e80b6de0f350b3a2bbad1671e07e2f1946c2b9d6`.

The declared Dev Containers graph could not build `devcontainer-engine`:

```console
swift build --disable-automatic-resolution --product devcontainer-engine
```

Its declared Engine API `0.3.3` graph does not contain the
`ProviderHandoffPortableLogging*` types used by the current Dev Containers
logging-handoff sources. A deliberately disposable overlay then selected the
source-matched local dependencies: Container
`a661e67c8e7713483eb448493c7b4a35f346d9b3`, Containerization
`cfb00bbf3523079fe2ab9fb6b8e9b3504eff77e5`, and Engine API
`4949e743675f00ec102f7acacdb4e990409e383f`. That resolves the handoff types,
but the same build stops at
`Sources/DevContainerAppleRuntime/AppleContainerRuntimeSupport.swift:65`:

```text
value of optional type 'CIDRv4?' must be unwrapped to refer to member
'address' of wrapped base type 'CIDRv4'
```

The source-matched Container graph intentionally makes an attachment's IPv4
address optional for IPv6-only networking. The checked-in Dev Containers
source still assumes a mandatory IPv4 address. This is a dependency/API
composition blocker, not C04 lifecycle evidence, and no shell-only manifest
overlay is a candidate release graph.

## Required change to resume

Establish and commit one coherent Dev Containers dependency contract that
contains both the logging-handoff Engine API types and the selected Container
attachment API. Update and focused-test the Apple runtime's address projection
for an attachment without IPv4 before using that graph for C04. The resulting
manifest, resolved graph, engine/Compose binaries, candidate Container binary,
guest/init archive, builder archive, and marker-protected runtime root must be
fingerprinted together before one fresh C04 invocation.

Only then rerun the focused candidate lane and reconcile its result with
[container-compose issue #184](https://github.com/stephenlclarke/container-compose/issues/184).
Do not close that issue or claim candidate parity from the Docker-only pass.

## Safe handoff

The two failed build commands above, the source revisions, and the exact
temporary overlay diff are sufficient to reproduce the blocker. The temporary
root contains no maintained source change and may be removed only after this
handoff checkpoint is clean. The Slack START thread is `1786039352.905009`;
reply there with the `Blocked` end state.
