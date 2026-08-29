# ``ComposeCore``

@Metadata {
  @PageImage(purpose: icon, source: "container-compose-docc-card.png", alt: "The container-compose DocC illustration: a light-blue octopus beside the standard three-row container service panel.")
  @PageImage(purpose: card, source: "container-compose-docc-card.png", alt: "The container-compose DocC card illustration: a light-blue octopus beside the standard three-row container service panel.")
}

Parse, normalize, and execute Compose projects with the `container` runtime.

## Overview

`ComposeCore` is the reusable Swift library behind the `compose` container plugin. It models Compose configuration, prepares runtime-neutral service execution plans, and orchestrates them through `ComposeRuntimeSPI` providers. The plugin supplies the matched [`stephenlclarke/container`](https://github.com/stephenlclarke/container)-backed provider; stock Apple releases do not yet expose every runtime primitive required by the supported lane.

The current 0.14.0 release negotiates a versioned runtime-capability manifest
before runtime-backed commands execute. Its matched provider includes the
logging-driver contract, attach-before-start lifecycle, advanced
networking/IPAM, archive and image-filesystem extensions, and the other
version-1 contracts documented in the [runtime capability guide](https://github.com/stephenlclarke/container-compose/blob/main/docs/architecture/runtime-capabilities.md).

The release also projects explicit dedicated/shared VM isolation, uses bounded
concurrent runtime bootstrap and eligible dedicated-VM prewarming in the
matched stack, and reuses one Container control-plane client per Compose
invocation without sharing attach or exec session ownership.

The generated reference covers the public configuration models and adapter protocols used to integrate Compose behavior into container-based tools.

## Topics

### Runtime Architecture

- <doc:Architecture>

### Container Ecosystem

- <doc:ContainerProjects>
