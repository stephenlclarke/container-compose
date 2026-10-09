# ``ComposeCore``

@Metadata {
  @PageImage(purpose: icon, source: "container-compose-docc-card.png", alt: "The container-compose DocC illustration: a light-blue octopus beside the standard three-row container service panel.")
  @PageImage(purpose: card, source: "container-compose-docc-card.png", alt: "The container-compose DocC card illustration: a light-blue octopus beside the standard three-row container service panel.")
}

Parse, normalize, and execute Compose projects with the `container` runtime.

## Overview

`ComposeCore` is the reusable Swift library behind the `compose` container plugin. It models Compose configuration, prepares runtime-neutral service execution plans, and orchestrates them through `ComposeRuntimeSPI` providers. The plugin supplies the matched [`stephenlclarke/container`](https://github.com/stephenlclarke/container)-backed provider; stock Apple releases do not yet expose every runtime primitive required by the supported lane.

The current stable release negotiates a versioned runtime-capability manifest
before runtime-backed commands execute. Its matched provider includes the
logging-driver contract, attach-before-start lifecycle, advanced
networking/IPAM, archive and image-filesystem extensions, and the other
version-1 contracts documented in the [runtime capability guide](https://github.com/stephenlclarke/container-compose/blob/main/docs/architecture/runtime-capabilities.md).

The release also projects explicit dedicated/shared VM isolation, uses bounded
concurrent runtime bootstrap and eligible dedicated-VM prewarming in the
matched stack, and reuses one Container control-plane client per Compose
invocation without sharing attach or exec session ownership.

The generated reference covers the public configuration models and adapter protocols used to integrate Compose behavior into container-based tools.

The unreleased Bazel candidate uses ``ComposeArgumentRewriter/argumentsForParsing(_:)`` to separate Compose options from a `run` or `exec` guest command. Compose options precede `SERVICE`; subsequent guest options, including `--help`, remain literal command arguments. ``ComposeArgumentRewriter/argumentsForOptionInspection(_:)`` applies the same service boundary when selecting Compose help and deciding whether the installed runtime requires a compatibility check. This candidate fix does not change the published stable support claim.

The unreleased candidate also publishes `config --output` (including variable listings) and `convert --output` through a same-directory temporary file, followed by atomic replacement. The resulting file is owner-readable/writable only (`0600`), including when replacing an existing file, because resolved configuration can contain sensitive environment values. Temporary staging remains on the destination volume; persistent runtime state locations are unchanged.

## Topics

### Runtime Architecture

- <doc:Architecture>

### Container Ecosystem

- <doc:ContainerProjects>
