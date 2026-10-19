# Issue: typed native launch loses a bare configuration ID

The enhanced typed create/run adapter passed raw native arguments to Container and ignored the typed service plan's image. A Compose request using bare `sha256:<config ID>` reached native creation, but its gateway inspection reported the resolved tag in `Config.Image`. The E13 image assertion correctly failed; no guest or release qualification is inferred from that attempt.

The launch boundary must carry the exact requested bare configuration ID in Compose's reserved image-reference label, while retaining the native image operand and guest arguments. Repo-qualified manifest digest requests keep their existing label behavior; ordinary tags keep their spelling. A caller cannot supply either reserved provenance or health label. The typed service plan and image operand must agree. Matching Devcontainer must prove a bare ID against the selected OCI manifest's config digest, not the manifest descriptor digest or mutable tag.

The implementation checkpoint is the `build/bazel-workflow` integration source for PR 708. Integration to Stephen-owned `main` is a separate stable-release gate; the qualified dependency release runs on the reviewed open PR 708 head.

Implementation handoff: [PR config-ID image provenance](PR-config-id-image-provenance.md).
