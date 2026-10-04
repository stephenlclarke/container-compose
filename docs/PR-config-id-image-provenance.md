# PR handoff: preserve native configuration-ID spelling

The shared native argument helper identifies the image after supported valued options, rejects reserved labels before the image, and inserts Compose's provenance label for bare `sha256:<64-hex>` and repo-qualified manifest digest requests. The typed adapter also checks the image against its create plan; the Engine fallback uses the same helper. Tag-only operands and guest arguments remain unchanged.

Focused regressions cover the five adaptive-memory valued options, a forged label after each value, inline and grouped options, `--` guest separation, bare IDs, repo digests, tags, and plan mismatch. The matching Devcontainer change independently validates bare IDs against descriptor/platform-bound OCI configuration identity. The previous E13 result remains failed; this patch requires a new exact-source build and live qualification before release.

This patch is prepared against the `build/bazel-workflow` integration source for PR 708. It is not merged to Stephen-owned `main` or a newly released Compose package.

Issue: [typed native image provenance](ISSUE-config-id-image-provenance.md).
