# [Bug]: Bridge conversion hangs when output is on an external volume

## Steps to reproduce

1. Place the Compose Bridge output directory on an external APFS volume.
2. Run `container compose bridge convert` with the official amd64 Docker Compose Bridge Kubernetes transformer.
3. Observe that the transformer container never reaches guest boot and the command times out.

The release-gate reproduction at `container-compose@307cabc8b883f0b5569a986b6ac48756dde6d253` timed out after 900 seconds. A process sample showed `VZVirtualMachineConfiguration` blocking while `VZMultipleDirectoryShare` opened the external output share. The internal input share and Rosetta share opened successfully, while the external output share did not. The guest produced no `vminitd` log because it never booted.

## Problem description

Apple Container uses Virtualization.framework directory shares for host bind mounts. On this host, opening a transformer output bind on an external volume can block VM startup indefinitely. Compose Bridge already writes its generated input to a private, runtime-safe temporary directory, but passes the user-selected output directory directly to the transformer as `/out`.

Stage `/out` beside the internal input directory and publish the completed output tree to the user-selected directory only after every transformation succeeds. This avoids the unsafe external share without introducing Docker into the product runtime or changing the user-visible output path.

## Environment

- OS: macOS 26
- Architecture: Apple silicon; official amd64 transformer through Rosetta
- Container: enhanced Apple-compatible runtime at `780a86b995ac4cb0985db97f38875fdc6e33d16b`
- container-compose: `307cabc8b883f0b5569a986b6ac48756dde6d253`

## Compose compatibility impact

The change affects only non-dry-run Bridge conversion with a non-empty output path. Transformer arguments and generated content remain Docker Compose Bridge compatible. Dry-run rendering, conversion without an output path, template mounts, output confirmation, and output permissions remain unchanged.

## Acceptance criteria

- [x] Transformer input and output mounts stay on the internal runtime-safe volume.
- [x] Completed output, including hidden and nested entries, is published to the requested directory.
- [x] Failed transformations do not publish staged output.
- [x] Temporary staging is removed after success and failure.
- [x] Output confirmation, replacement, and permissions remain unchanged.
- [x] Enhanced focused and component tests pass for the pull-request implementation.
- [x] The stock runtime profile builds and tests pass for the pull-request implementation.
- [x] The real external-volume Docker Compose Bridge parity case completes.
- [ ] Exact-head review and applicable CI/quality gates pass.

## Runtime evidence

The fixed candidate completed the official Kubernetes transformer in 24.00 seconds with its output directory on the external APFS volume. A recursive comparison against Docker Compose's maintained `expected-kubernetes` fixture was byte-for-byte clean. The run used the signed enhanced Container candidate at `780a86b995ac4cb0985db97f38875fdc6e33d16b`, built and restarted with the exact Containerization guest source at `7e066a3101bc84fa0f7231daf6a03aa9ef62a567`, and did not use Docker Engine.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
- [x] I searched existing issue records before creating [issue #645](https://github.com/stephenlclarke/container-compose/issues/645).
- [x] I removed secrets and private data from this report.
